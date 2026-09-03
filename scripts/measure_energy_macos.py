import collections
import ctypes
import ctypes.util
import os
import resource
import subprocess
import sys
import time


class RusageInfoV6(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        *[
            (name, ctypes.c_uint64)
            for name in (
                "user_time",
                "system_time",
                "pkg_idle_wkups",
                "interrupt_wkups",
                "pageins",
                "wired_size",
                "resident_size",
                "phys_footprint",
                "proc_start_abstime",
                "proc_exit_abstime",
                "child_user_time",
                "child_system_time",
                "child_pkg_idle_wkups",
                "child_interrupt_wkups",
                "child_pageins",
                "child_elapsed_abstime",
                "diskio_bytesread",
                "diskio_byteswritten",
                "cpu_time_qos_default",
                "cpu_time_qos_maintenance",
                "cpu_time_qos_background",
                "cpu_time_qos_utility",
                "cpu_time_qos_legacy",
                "cpu_time_qos_user_initiated",
                "cpu_time_qos_user_interactive",
                "billed_system_time",
                "serviced_system_time",
                "logical_writes",
                "lifetime_max_phys_footprint",
                "instructions",
                "cycles",
                "billed_energy",
                "serviced_energy",
                "interval_max_phys_footprint",
                "runnable_time",
                "flags",
                "user_ptime",
                "system_ptime",
                "pinstructions",
                "pcycles",
                "energy_nj",
                "penergy_nj",
                "secure_time_in_system",
                "secure_ptime_in_system",
                "neural_footprint",
                "lifetime_max_neural_footprint",
                "interval_max_neural_footprint",
            )
        ],
        ("reserved", ctypes.c_uint64 * 9),
    ]


if len(sys.argv) < 2:
    raise SystemExit("usage: measure_energy_macos.py command [args ...]")

libproc = ctypes.CDLL(ctypes.util.find_library("proc"), use_errno=True)
libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libproc.proc_listallpids.restype = ctypes.c_int
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageInfoV6)]
libproc.proc_pid_rusage.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int

libsystem = ctypes.CDLL(ctypes.util.find_library("System"), use_errno=True)
libsystem.mach_timebase_info.argtypes = [ctypes.POINTER(ctypes.c_uint32 * 2)]
libsystem.mach_timebase_info.restype = ctypes.c_int

pid_buffer = (ctypes.c_int * 65536)()
path_buffer = ctypes.create_string_buffer(4096)
records = {}
# Executable path per process, refreshed with every sample that raised its energy: a process seen
# first as `sh` and later as the compiler it exec'd is charged to the compiler.
names = {}


def sample_process_group(process_group):
    count = libproc.proc_listallpids(pid_buffer, ctypes.sizeof(pid_buffer))
    for index in range(max(0, count)):
        pid = pid_buffer[index]
        try:
            if os.getpgid(pid) != process_group:
                continue
        except (PermissionError, ProcessLookupError):
            continue
        usage = RusageInfoV6()
        if libproc.proc_pid_rusage(pid, 6, ctypes.byref(usage)) != 0:
            continue
        key = (pid, usage.proc_start_abstime)
        old = records.get(key)
        if old is None or usage.energy_nj > old.energy_nj:
            records[key] = usage
            if libproc.proc_pidpath(pid, path_buffer, 4096) > 0:
                names[key] = path_buffer.value.decode(errors="replace")


before = resource.getrusage(resource.RUSAGE_CHILDREN)
started = time.monotonic()
process = subprocess.Popen(sys.argv[1:], start_new_session=True)
process_group = os.getpgid(process.pid)
while process.poll() is None:
    sample_process_group(process_group)
    time.sleep(0.001)
sample_process_group(process_group)
ended = time.monotonic()
after = resource.getrusage(resource.RUSAGE_CHILDREN)

timebase = (ctypes.c_uint32 * 2)()
if libsystem.mach_timebase_info(ctypes.byref(timebase)) != 0:
    raise SystemExit("mach_timebase_info failed")

seconds_per_tick = timebase[0] / timebase[1] / 1_000_000_000
energy_j = sum(record.energy_nj for record in records.values()) / 1_000_000_000
penergy_j = sum(record.penergy_nj for record in records.values()) / 1_000_000_000
sampled_cpu_s = sum(record.user_time + record.system_time for record in records.values()) * seconds_per_tick
reference_cpu_s = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
wall_s = ended - started
coverage_pct = 100 * sampled_cpu_s / reference_cpu_s if reference_cpu_s != 0 else 0
print(
    f"ENERGY wall_s={wall_s:.6f} energy_j={energy_j:.6f} penergy_j={penergy_j:.6f} "
    f"average_w={energy_j / wall_s:.6f} sampled_cpu_s={sampled_cpu_s:.6f} "
    f"reference_cpu_s={reference_cpu_s:.6f} coverage_pct={coverage_pct:.4f} "
    f"processes={len(records)} exit={process.returncode}"
)
by_command = collections.defaultdict(lambda: [0, 0.0, 0.0])
for key, record in records.items():
    row = by_command[os.path.basename(names.get(key, "?"))]
    row[0] += 1
    row[1] += record.energy_nj / 1_000_000_000
    row[2] += (record.user_time + record.system_time) * seconds_per_tick
print(f"{'command':30} {'count':>6} {'energy_j':>10} {'cpu_s':>8}")
for name, (count, joules, cpu_s) in sorted(by_command.items(), key=lambda item: -item[1][1]):
    if joules < 0.5:
        continue
    print(f"{name:30} {count:6d} {joules:10.2f} {cpu_s:8.2f}")
raise SystemExit(process.returncode)
