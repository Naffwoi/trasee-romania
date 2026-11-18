package live

import (
	"hash/fnv"
	"math"
	"sync"
	"time"
)

const (
	limiterShardCount         = 32
	maxTrackedDevicesTotal    = 10_240
	maxTrackedDevicesPerShard = maxTrackedDevicesTotal / limiterShardCount // 320
)

// RateLimitDecision describes the sliding-window decision for one device key.
type RateLimitDecision struct {
	Allowed       bool
	Remaining     int
	RetryAfterSec int
}

type limiterShard struct {
	mu      sync.Mutex
	buckets map[string][]int64
}

// SlidingWindowLimiter implements a 32-shard thread-safe sliding-window rate limiter.
type SlidingWindowLimiter struct {
	maxRequests int
	windowNs    int64
	shards      [limiterShardCount]limiterShard
}

// NewSlidingWindowLimiter creates a limiter allowing at most maxRequests per window.
func NewSlidingWindowLimiter(maxRequests int, window time.Duration) *SlidingWindowLimiter {
	l := &SlidingWindowLimiter{
		maxRequests: maxRequests,
		windowNs:    window.Nanoseconds(),
	}
	for i := range l.shards {
		l.shards[i].buckets = make(map[string][]int64, 32)
	}
	return l
}

func (l *SlidingWindowLimiter) shardFor(key string) *limiterShard {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	return &l.shards[h.Sum32()&(limiterShardCount-1)]
}

// Check records a request for key at now and returns whether it is allowed.
func (l *SlidingWindowLimiter) Check(key string, now time.Time) RateLimitDecision {
	if key == "" {
		key = "anonymous"
	}
	nowNs := now.UnixNano()
	cutoffNs := nowNs - l.windowNs
	sh := l.shardFor(key)

	sh.mu.Lock()
	defer sh.mu.Unlock()

	existing := sh.buckets[key]
	firstValid := 0
	for firstValid < len(existing) && existing[firstValid] <= cutoffNs {
		firstValid++
	}
	var active []int64
	if firstValid == len(existing) {
		delete(sh.buckets, key)
	} else if firstValid > 0 {
		n := copy(existing, existing[firstValid:])
		active = existing[:n]
	} else {
		active = existing
	}

	if len(active) >= l.maxRequests {
		sh.buckets[key] = active
		oldestNs := active[0]
		remSec := math.Ceil(float64(oldestNs+l.windowNs-nowNs) / float64(time.Second))
		retrySec := int(remSec)
		if retrySec < 1 {
			retrySec = 1
		}
		return RateLimitDecision{
			Allowed:       false,
			Remaining:     0,
			RetryAfterSec: retrySec,
		}
	}

	if len(active) == 0 && len(sh.buckets) >= maxTrackedDevicesPerShard {
		for k, ts := range sh.buckets {
			if len(ts) == 0 || ts[len(ts)-1] <= cutoffNs {
				delete(sh.buckets, k)
			}
		}
		if len(sh.buckets) >= maxTrackedDevicesPerShard {
			clear(sh.buckets)
		}
	}

	if active == nil {
		active = make([]int64, 0, l.maxRequests)
	}
	active = append(active, nowNs)
	sh.buckets[key] = active

	rem := l.maxRequests - len(active)
	if rem < 0 {
		rem = 0
	}
	return RateLimitDecision{
		Allowed:       true,
		Remaining:     rem,
		RetryAfterSec: 0,
	}
}

// Reset clears all shards.
func (l *SlidingWindowLimiter) Reset() {
	for i := range l.shards {
		l.shards[i].mu.Lock()
		clear(l.shards[i].buckets)
		l.shards[i].mu.Unlock()
	}
}

// TotalTrackedKeys returns the total active keys across all shards.
func (l *SlidingWindowLimiter) TotalTrackedKeys() int {
	total := 0
	for i := range l.shards {
		l.shards[i].mu.Lock()
		total += len(l.shards[i].buckets)
		l.shards[i].mu.Unlock()
	}
	return total
}

// LiveRateLimiterSet groups the 11 endpoint thresholds matching device_identity.ts.
type LiveRateLimiterSet struct {
	Heartbeat     *SlidingWindowLimiter
	Reports       *SlidingWindowLimiter
	Votes         *SlidingWindowLimiter
	Sos           *SlidingWindowLimiter
	SosRelay      *SlidingWindowLimiter
	SosUpdate     *SlidingWindowLimiter
	SosRespond    *SlidingWindowLimiter
	PushSubscribe *SlidingWindowLimiter
	GroupCreate   *SlidingWindowLimiter
	GroupJoin     *SlidingWindowLimiter
	GroupPing     *SlidingWindowLimiter
}

// NewDefaultLiveRateLimiterSet builds the standard /api/v1/live/* rate limiters.
func NewDefaultLiveRateLimiterSet() *LiveRateLimiterSet {
	return &LiveRateLimiterSet{
		Heartbeat:     NewSlidingWindowLimiter(6, time.Minute),
		Reports:       NewSlidingWindowLimiter(6, 10*time.Minute),
		Votes:         NewSlidingWindowLimiter(20, 5*time.Minute),
		Sos:           NewSlidingWindowLimiter(3, 15*time.Minute),
		SosRelay:      NewSlidingWindowLimiter(20, 5*time.Minute),
		SosUpdate:     NewSlidingWindowLimiter(30, time.Minute),
		SosRespond:    NewSlidingWindowLimiter(30, time.Minute),
		PushSubscribe: NewSlidingWindowLimiter(12, 5*time.Minute),
		GroupCreate:   NewSlidingWindowLimiter(10, 10*time.Minute),
		GroupJoin:     NewSlidingWindowLimiter(15, 5*time.Minute),
		GroupPing:     NewSlidingWindowLimiter(30, time.Minute),
	}
}
