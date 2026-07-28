// Goroutines: each one makes the blocking syscalls itself. The runtime detaches the P from the M around a
// blocking call, so the other goroutines queued on that thread keep running elsewhere.
package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// Create a file, write 4 KiB, sync it to the device, close. File.Sync issues F_FULLFSYNC on darwin, which
// is the real barrier -- plain fsync there only reaches the device cache.
func unit(id int) {
	f, err := os.OpenFile(fmt.Sprintf("%s/f%d", dir, id), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return
	}
	f.Write(buf4k)
	f.Sync()
	f.Close()
}

const dir = "/tmp/sc-compare"

var buf4k = make([]byte, 4096)

func env(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func main() {
	iters, tasks := env("ITERS", 5), env("TASKS", 1000)
	start := time.Now()
	for i := 0; i < iters; i++ {
		var wg sync.WaitGroup
		wg.Add(tasks)
		for t := 0; t < tasks; t++ {
			id := t
			go func() { defer wg.Done(); unit(id) }()
		}
		wg.Wait()
	}
	el := time.Since(start)
	fmt.Printf("%.1f %.0f\n", el.Seconds()*1000/float64(iters), float64(el.Nanoseconds())/float64(iters*tasks))
}
