// Goroutines: each one makes the blocking syscalls itself. The runtime detaches the P from the M around a
// blocking call, so the other goroutines queued on that thread keep running elsewhere. Go has no pool to
// shut down explicitly; the process exit is the teardown.
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"
)

var buf4k = make([]byte, 4096) // the identical payload of every lane: 4 KiB of zeros

// Create a file, write 4 KiB, sync it to the device, close. File.Sync issues F_FULLFSYNC on darwin, which
// is the real barrier -- plain fsync there only reaches the device cache. True only when every call
// succeeded with the full count.
func unit(dir string, id int) bool {
	f, err := os.OpenFile(fmt.Sprintf("%s/f%d", dir, id), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return false
	}
	n, err := f.Write(buf4k)
	ok := err == nil && n == len(buf4k)
	if f.Sync() != nil {
		ok = false
	}
	if f.Close() != nil {
		ok = false
	}
	return ok
}

func env(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func main() {
	iters, tasks, limit := env("ITERS", 5), env("TASKS", 1000), env("LIMIT", 64)
	dir := os.Getenv("SC_COMPARE_DIR")
	if dir == "" {
		fmt.Fprintln(os.Stderr, "go: SC_COMPARE_DIR is not set")
		os.Exit(2)
	}
	sem := make(chan struct{}, limit) // the effective concurrency limit, matched across lanes
	var okCount int64
	var mu sync.Mutex
	samples := make([]float64, 0, iters)
	for i := 0; i < iters; i++ {
		t0 := time.Now()
		var wg sync.WaitGroup
		wg.Add(tasks)
		for t := 0; t < tasks; t++ {
			id := t
			go func() {
				defer wg.Done()
				sem <- struct{}{}
				ok := unit(dir, id)
				<-sem
				if ok {
					mu.Lock()
					okCount++
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		samples = append(samples, float64(time.Since(t0).Nanoseconds())/1e6)
	}
	report(samples, tasks, okCount, int64(iters*tasks), limit)
}

// cold_ms median_ms p95_ms ns_per_op ok total limit: the first iteration apart (it pays for the runtime's
// start), the distribution of the rest, and the validated work.
func report(samples []float64, tasks int, ok, total int64, limit int) {
	cold := samples[0]
	rest := append([]float64(nil), samples[1:]...)
	if len(rest) == 0 {
		rest = samples
	}
	sort.Float64s(rest)
	median := rest[len(rest)/2]
	if len(rest)%2 == 0 {
		median = (rest[len(rest)/2-1] + rest[len(rest)/2]) / 2
	}
	p95 := rest[(len(rest)*95+99)/100-1]
	fmt.Printf("%.1f %.1f %.1f %.0f %d %d %d\n", cold, median, p95, median*1e6/float64(tasks), ok, total, limit)
	if ok != total {
		os.Exit(1)
	}
}
