# -*- coding: utf-8 -*-
import ctypes
import json
import os
import queue
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText


APP_TITLE = "U盘格式化提示修复工具"
ROOT_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_ROOT = ROOT_DIR / "repair-output"
FIRST_BACKUP_SIZE = 1024 * 1024
SECTOR_SIZE = 512


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin() -> None:
    if getattr(sys, "frozen", False):
        executable = sys.executable
        params = ""
    else:
        executable = sys.executable
        params = f'"{Path(__file__).resolve()}"'

    result = ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",
        executable,
        params,
        None,
        1,
    )
    if result <= 32:
        raise RuntimeError("无法申请管理员权限。")
    raise SystemExit(0)


def format_bytes(num: int) -> str:
    value = float(num)
    units = ["B", "KB", "MB", "GB", "TB"]
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024
        idx += 1
    return f"{value:.2f} {units[idx]}"


def run_powershell(script: str) -> str:
    completed = subprocess.run(
        ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=True,
    )
    return completed.stdout.strip()


def run_powershell_json(script: str):
    output = run_powershell(script)
    if not output:
        return []
    data = json.loads(output)
    if isinstance(data, list):
        return data
    return [data]


def get_usb_disks():
    script = r"""
Get-Disk |
Where-Object { $_.BusType -eq 'USB' -or $_.FriendlyName -match 'USB|Flash|Removable|UFD' } |
Select-Object Number,FriendlyName,BusType,PartitionStyle,HealthStatus,OperationalStatus,Size |
ConvertTo-Json -Depth 4 -Compress
"""
    return run_powershell_json(script)


def get_disk_info(disk_number: int):
    script = rf"""
Get-Disk -Number {disk_number} |
Select-Object Number,FriendlyName,BusType,PartitionStyle,HealthStatus,OperationalStatus,Size |
ConvertTo-Json -Depth 4 -Compress
"""
    data = run_powershell_json(script)
    return data[0] if data else None


def get_partitions(disk_number: int):
    script = rf"""
$parts = Get-Partition -DiskNumber {disk_number} -ErrorAction SilentlyContinue |
Select-Object PartitionNumber,DriveLetter,Offset,Size,Type
if ($parts) {{ $parts | ConvertTo-Json -Depth 4 -Compress }}
"""
    return run_powershell_json(script)


def get_volume(drive_letter: str):
    script = rf"""
Get-Volume -DriveLetter {drive_letter} -ErrorAction SilentlyContinue |
Select-Object DriveLetter,FileSystem,FileSystemLabel,Size,SizeRemaining,HealthStatus |
ConvertTo-Json -Depth 4 -Compress
"""
    data = run_powershell_json(script)
    return data[0] if data else None


def set_disk_readonly(disk_number: int, readonly: bool) -> None:
    value = "$true" if readonly else "$false"
    run_powershell(f"Set-Disk -Number {disk_number} -IsReadOnly {value}")


def refresh_storage_cache() -> None:
    run_powershell("Update-HostStorageCache")


def open_physical_drive(disk_number: int, write: bool = False):
    access = "r+b" if write else "rb"
    return open(rf"\\.\PhysicalDrive{disk_number}", access)


def read_exact(stream, offset: int, count: int) -> bytes:
    stream.seek(offset)
    data = stream.read(count)
    if len(data) != count:
        raise RuntimeError(f"读取磁盘失败，偏移 {offset}。")
    return data


def backup_first_mib(disk_number: int, output_path: Path) -> None:
    with open_physical_drive(disk_number, write=False) as stream:
        output_path.write_bytes(read_exact(stream, 0, FIRST_BACKUP_SIZE))


def create_disk_image(disk_number: int, disk_size: int, output_path: Path, progress_cb) -> None:
    copied = 0
    chunk_size = 4 * 1024 * 1024
    with open_physical_drive(disk_number, write=False) as src, output_path.open("wb") as dst:
        while True:
            chunk = src.read(chunk_size)
            if not chunk:
                break
            dst.write(chunk)
            copied += len(chunk)
            progress_cb(copied, disk_size)


def get_mbr_state(sector0: bytes) -> dict:
    entry = sector0[446:510]
    signature_ok = sector0[510:512] == b"\x55\xaa"
    all_zero = all(b == 0x00 for b in entry)
    all_ff = all(b == 0xFF for b in entry)
    likely_partition = sector0[450] not in (0x00, 0xFF)
    return {
        "signature_ok": signature_ok,
        "all_zero": all_zero,
        "all_ff": all_ff,
        "likely_partition": likely_partition,
        "missing_or_broken": (not signature_ok) or all_zero or all_ff or (not likely_partition),
    }


def parse_fat32_candidate(sector: bytes, lba: int):
    if len(sector) < SECTOR_SIZE:
        return None

    jump_ok = ((sector[0] == 0xEB and sector[2] == 0x90) or sector[0] == 0xE9)
    signature_ok = sector[510:512] == b"\x55\xaa"
    fs_name = sector[82:90].decode("ascii", errors="ignore").strip()
    bytes_per_sector = int.from_bytes(sector[11:13], "little")
    sectors_per_cluster = sector[13]
    reserved_sectors = int.from_bytes(sector[14:16], "little")
    number_of_fats = sector[16]
    hidden_sectors = int.from_bytes(sector[28:32], "little")
    total_sectors = int.from_bytes(sector[32:36], "little")
    fat_size = int.from_bytes(sector[36:40], "little")
    root_cluster = int.from_bytes(sector[44:48], "little")
    fsinfo_sector = int.from_bytes(sector[48:50], "little")
    backup_boot_sector = int.from_bytes(sector[50:52], "little")

    if not jump_ok or not signature_ok:
        return None
    if fs_name != "FAT32":
        return None
    if bytes_per_sector not in (512, 1024, 2048, 4096):
        return None
    if sectors_per_cluster not in (1, 2, 4, 8, 16, 32, 64, 128):
        return None
    if reserved_sectors < 32 or number_of_fats not in (1, 2):
        return None
    if total_sectors <= 0 or fat_size <= 0 or root_cluster < 2:
        return None
    if hidden_sectors != lba:
        return None

    return {
        "lba": lba,
        "bytes_per_sector": bytes_per_sector,
        "sectors_per_cluster": sectors_per_cluster,
        "reserved_sectors": reserved_sectors,
        "number_of_fats": number_of_fats,
        "hidden_sectors": hidden_sectors,
        "total_sectors": total_sectors,
        "fat_size": fat_size,
        "root_cluster": root_cluster,
        "fsinfo_sector": fsinfo_sector,
        "backup_boot_sector": backup_boot_sector,
        "partition_type": 0x0C,
    }


def find_fat32_candidate(disk_number: int, max_lba_to_scan: int = 2048):
    candidates = []
    with open_physical_drive(disk_number, write=False) as stream:
        for lba in range(1, max_lba_to_scan + 1):
            sector = read_exact(stream, lba * SECTOR_SIZE, SECTOR_SIZE)
            candidate = parse_fat32_candidate(sector, lba)
            if not candidate:
                continue

            backup_lba = candidate["lba"] + candidate["backup_boot_sector"]
            if backup_lba <= max_lba_to_scan:
                backup = read_exact(stream, backup_lba * SECTOR_SIZE, SECTOR_SIZE)
                backup_valid = (
                    backup[510:512] == b"\x55\xaa"
                    and backup[82:90].decode("ascii", errors="ignore").strip() == "FAT32"
                )
                if not backup_valid:
                    continue

            candidates.append(candidate)

    return candidates


def build_mbr_sector(start_lba: int, sector_count: int, partition_type: int) -> bytes:
    mbr = bytearray(512)
    mbr[440:444] = bytes([0x55, 0x53, 0x42, 0x52])
    mbr[446] = 0x00
    mbr[447] = 0x00
    mbr[448] = 0x02
    mbr[449] = 0x00
    mbr[450] = partition_type
    mbr[451] = 0xFE
    mbr[452] = 0xFF
    mbr[453] = 0xFF
    mbr[454:458] = int(start_lba).to_bytes(4, "little")
    mbr[458:462] = int(sector_count).to_bytes(4, "little")
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def write_sector0(disk_number: int, sector_bytes: bytes) -> None:
    with open_physical_drive(disk_number, write=True) as stream:
        stream.seek(0)
        stream.write(sector_bytes)
        stream.flush()


class RepairApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("980x720")
        self.root.minsize(900, 660)

        self.queue = queue.Queue()
        self.current_output_dir = None

        self.output_root_var = tk.StringVar(value=str(DEFAULT_OUTPUT_ROOT))
        self.create_image_var = tk.BooleanVar(value=True)
        self.allow_write_var = tk.BooleanVar(value=True)
        self.status_var = tk.StringVar(value="就绪")

        self._build_ui()
        self.refresh_disks()
        self.root.after(150, self._poll_queue)

    def _build_ui(self):
        top = ttk.Frame(self.root, padding=12)
        top.pack(fill="both", expand=True)

        header = ttk.Label(
            top,
            text="U盘格式化提示修复工具",
            font=("Microsoft YaHei UI", 18, "bold"),
        )
        header.pack(anchor="w")

        subtitle = ttk.Label(
            top,
            text="适用于“Windows 提示需要格式化，但怀疑只是 MBR 丢失、FAT32 还在”的场景。工具会先做备份，再决定是否回写最小 MBR。",
            wraplength=900,
        )
        subtitle.pack(anchor="w", pady=(6, 12))

        disk_frame = ttk.LabelFrame(top, text="1. 选择 USB 磁盘", padding=10)
        disk_frame.pack(fill="x")

        columns = ("number", "name", "size", "style", "health")
        self.disk_tree = ttk.Treeview(disk_frame, columns=columns, show="headings", height=6)
        headings = {
            "number": "Disk",
            "name": "设备名称",
            "size": "容量",
            "style": "分区样式",
            "health": "健康状态",
        }
        widths = {"number": 70, "name": 400, "size": 130, "style": 120, "health": 120}
        for key in columns:
            self.disk_tree.heading(key, text=headings[key])
            self.disk_tree.column(key, width=widths[key], anchor="center" if key != "name" else "w")
        self.disk_tree.pack(fill="x")

        disk_buttons = ttk.Frame(disk_frame)
        disk_buttons.pack(fill="x", pady=(10, 0))
        ttk.Button(disk_buttons, text="刷新 USB 磁盘", command=self.refresh_disks).pack(side="left")

        options = ttk.LabelFrame(top, text="2. 输出和修复选项", padding=10)
        options.pack(fill="x", pady=(12, 0))

        output_row = ttk.Frame(options)
        output_row.pack(fill="x")
        ttk.Label(output_row, text="输出目录：").pack(side="left")
        ttk.Entry(output_row, textvariable=self.output_root_var).pack(side="left", fill="x", expand=True, padx=(6, 6))
        ttk.Button(output_row, text="选择目录", command=self.choose_output_dir).pack(side="left")

        ttk.Checkbutton(
            options,
            text="先做整盘镜像备份（推荐，需要额外磁盘空间）",
            variable=self.create_image_var,
        ).pack(anchor="w", pady=(10, 0))
        ttk.Checkbutton(
            options,
            text="如果确认安全，自动回写最小 MBR",
            variable=self.allow_write_var,
        ).pack(anchor="w", pady=(6, 0))

        action_row = ttk.Frame(top)
        action_row.pack(fill="x", pady=(12, 0))
        ttk.Button(action_row, text="开始修复", command=self.start_repair).pack(side="left")
        ttk.Button(action_row, text="打开输出目录", command=self.open_output_dir).pack(side="left", padx=(8, 0))

        progress_frame = ttk.Frame(top)
        progress_frame.pack(fill="x", pady=(12, 0))
        self.progress = ttk.Progressbar(progress_frame, mode="determinate")
        self.progress.pack(fill="x")
        ttk.Label(progress_frame, textvariable=self.status_var).pack(anchor="w", pady=(6, 0))

        log_frame = ttk.LabelFrame(top, text="运行日志", padding=10)
        log_frame.pack(fill="both", expand=True, pady=(12, 0))
        self.log_text = ScrolledText(log_frame, height=20, font=("Consolas", 10))
        self.log_text.pack(fill="both", expand=True)
        self.log_text.configure(state="disabled")

    def append_log(self, text: str):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", text + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def set_status(self, text: str):
        self.status_var.set(text)

    def choose_output_dir(self):
        path = filedialog.askdirectory(initialdir=self.output_root_var.get() or str(ROOT_DIR))
        if path:
            self.output_root_var.set(path)

    def open_output_dir(self):
        path = self.current_output_dir or self.output_root_var.get()
        if path and Path(path).exists():
            os.startfile(path)
        else:
            messagebox.showinfo(APP_TITLE, "还没有可打开的输出目录。")

    def refresh_disks(self):
        for item in self.disk_tree.get_children():
            self.disk_tree.delete(item)
        try:
            disks = get_usb_disks()
        except Exception as exc:
            messagebox.showerror(APP_TITLE, f"读取 USB 磁盘失败：\n{exc}")
            return

        for disk in disks:
            self.disk_tree.insert(
                "",
                "end",
                values=(
                    disk["Number"],
                    disk["FriendlyName"],
                    format_bytes(int(disk["Size"])),
                    disk["PartitionStyle"],
                    disk["HealthStatus"],
                ),
            )

        self.append_log("已刷新 USB 磁盘列表。")

    def selected_disk_number(self):
        selection = self.disk_tree.selection()
        if not selection:
            return None
        values = self.disk_tree.item(selection[0], "values")
        return int(values[0])

    def start_repair(self):
        disk_number = self.selected_disk_number()
        if disk_number is None:
            messagebox.showwarning(APP_TITLE, "请先选择一个 USB 磁盘。")
            return

        output_root = Path(self.output_root_var.get()).expanduser()
        output_root.mkdir(parents=True, exist_ok=True)

        disk = get_disk_info(disk_number)
        if not disk:
            messagebox.showerror(APP_TITLE, "读取磁盘信息失败。")
            return

        confirm = messagebox.askyesno(
            APP_TITLE,
            f"将处理 Disk {disk_number}\n\n"
            f"设备：{disk['FriendlyName']}\n"
            f"容量：{format_bytes(int(disk['Size']))}\n\n"
            "工具会先做备份，再尝试最小修复。\n是否继续？",
        )
        if not confirm:
            return

        self.progress.configure(value=0)
        self.set_status("正在准备...")
        self.append_log(f"开始处理 Disk {disk_number} - {disk['FriendlyName']}")

        worker = threading.Thread(
            target=self._repair_worker,
            args=(disk_number, output_root, bool(self.create_image_var.get()), bool(self.allow_write_var.get())),
            daemon=True,
        )
        worker.start()

    def _repair_worker(self, disk_number: int, output_root: Path, create_image: bool, allow_write: bool):
        def log(msg: str):
            self.queue.put(("log", msg))

        def status(msg: str):
            self.queue.put(("status", msg))

        def progress(done: int, total: int):
            pct = 0 if total <= 0 else min(100, int(done * 100 / total))
            self.queue.put(("progress", pct))
            self.queue.put(("status", f"正在创建整盘镜像：{format_bytes(done)} / {format_bytes(total)}"))

        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output_dir = output_root / f"usb-repair-disk{disk_number}-{timestamp}"
        output_dir.mkdir(parents=True, exist_ok=True)
        self.current_output_dir = str(output_dir)

        try:
            log(f"输出目录：{output_dir}")
            disk = get_disk_info(disk_number)
            if not disk:
                raise RuntimeError("无法读取磁盘信息。")

            status("正在保护原盘...")
            set_disk_readonly(disk_number, True)
            log("已将磁盘设为只读。")

            first_mib_path = output_dir / "first-1MiB-before-repair.bin"
            backup_first_mib(disk_number, first_mib_path)
            log(f"已备份前 1 MiB：{first_mib_path}")

            if create_image:
                status("准备整盘镜像...")
                image_path = output_dir / f"disk{disk_number}-{timestamp}.img"
                create_disk_image(disk_number, int(disk["Size"]), image_path, progress)
                log(f"整盘镜像完成：{image_path}")

            status("正在分析盘头...")
            with open_physical_drive(disk_number, write=False) as stream:
                sector0 = read_exact(stream, 0, SECTOR_SIZE)

            mbr_state = get_mbr_state(sector0)
            if not mbr_state["missing_or_broken"]:
                raise RuntimeError("这块盘的 MBR 看起来并没有丢失，不属于本工具的安全自动修复范围。")

            candidates = find_fat32_candidate(disk_number, max_lba_to_scan=2048)
            if not candidates:
                raise RuntimeError("没有找到可安全自动修复的 FAT32 启动扇区。")
            if len(candidates) > 1:
                raise RuntimeError("发现了多个候选分区，风险过高，已停止自动修复。")

            candidate = candidates[0]
            log(
                "找到 FAT32 候选分区："
                f" 起点 LBA={candidate['lba']}, 总扇区={candidate['total_sectors']},"
                f" 每簇扇区={candidate['sectors_per_cluster']}"
            )

            mbr_path = output_dir / "rebuilt-mbr-sector0.bin"
            new_mbr = build_mbr_sector(candidate["lba"], candidate["total_sectors"], candidate["partition_type"])
            mbr_path.write_bytes(new_mbr)
            log(f"已生成最小 MBR：{mbr_path}")

            if not allow_write:
                raise RuntimeError("当前已关闭自动写回选项。备份和分析结果已保存，但不会写盘。")

            status("正在写回最小 MBR...")
            set_disk_readonly(disk_number, False)
            write_sector0(disk_number, new_mbr)
            refresh_storage_cache()
            time.sleep(3)
            log("最小 MBR 已写回，正在验证...")

            partitions = get_partitions(disk_number)
            if not partitions:
                raise RuntimeError("写回后系统仍未识别出分区。")

            drive_letter = ""
            for part in partitions:
                if part.get("DriveLetter"):
                    drive_letter = part["DriveLetter"]
                    break

            summary_lines = [
                f"DiskNumber={disk_number}",
                f"FriendlyName={disk['FriendlyName']}",
                f"CandidateLba={candidate['lba']}",
                f"CandidateTotalSectors={candidate['total_sectors']}",
                f"DriveLetter={drive_letter}",
                "Status=Success",
            ]

            if drive_letter:
                volume = get_volume(drive_letter)
                if volume:
                    log(
                        f"卷信息：{drive_letter}: {volume['FileSystem']} {volume['FileSystemLabel']} "
                        f"总容量 {format_bytes(int(volume['Size']))}"
                    )
                try:
                    entries = os.listdir(f"{drive_letter}:\\")[:10]
                    log("根目录前几项：" + ", ".join(entries) if entries else "根目录为空。")
                except Exception as exc:
                    log(f"根目录读取失败：{exc}")
            else:
                log("系统识别出了分区，但暂时没有盘符。")

            (output_dir / "summary.txt").write_text("\n".join(summary_lines), encoding="utf-8")
            self.queue.put(("progress", 100))
            self.queue.put(("done", f"修复完成。\n输出目录：{output_dir}"))

        except Exception as exc:
            (output_dir / "error.txt").write_text(str(exc), encoding="utf-8")
            self.queue.put(("error", f"{exc}\n\n输出目录：{output_dir}"))

    def _poll_queue(self):
        while True:
            try:
                kind, payload = self.queue.get_nowait()
            except queue.Empty:
                break

            if kind == "log":
                self.append_log(payload)
            elif kind == "status":
                self.set_status(payload)
            elif kind == "progress":
                self.progress.configure(value=payload)
            elif kind == "done":
                self.set_status("完成")
                self.append_log(payload)
                messagebox.showinfo(APP_TITLE, payload)
            elif kind == "error":
                self.set_status("已停止")
                self.append_log("错误：" + payload)
                messagebox.showerror(APP_TITLE, payload)

        self.root.after(150, self._poll_queue)


def main():
    if not is_admin():
        relaunch_as_admin()

    DEFAULT_OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    root = tk.Tk()
    style = ttk.Style(root)
    if "vista" in style.theme_names():
        style.theme_use("vista")
    app = RepairApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
