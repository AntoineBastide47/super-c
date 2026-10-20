/* Process CPU time on Windows, for ffi/time.spc `cpu_seconds`: the Windows C runtime's `clock()` counts
   wall time since the process started, so `time` binds this header on Windows only. */
#ifndef SC_TIME_H
#define SC_TIME_H

/* User plus kernel time of every thread of the process, in nanoseconds; -1 when the query fails. */
long long sc_time_cpu_ns(void);

#endif
