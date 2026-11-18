package routes

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"pocketbase/services/live"
)

type liveTrustedEdgeContextKey struct{}

func markTrustedPublicLiveRequest(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), liveTrustedEdgeContextKey{}, true))
}

func isTrustedPublicLiveRequest(r *http.Request) bool {
	if r == nil {
		return false
	}
	v, _ := r.Context().Value(liveTrustedEdgeContextKey{}).(bool)
	return v
}

func clientRateLimitFallbackKey(e *core.RequestEvent) string {
	if ip := strings.TrimSpace(e.RealIP()); ip != "" {
		return "ip:" + ip
	}
	if e.Request != nil {
		if host, _, err := net.SplitHostPort(e.Request.RemoteAddr); err == nil && host != "" {
			return "ip:" + host
		}
		if e.Request.RemoteAddr != "" {
			return "ip:" + e.Request.RemoteAddr
		}
	}
	return "anonymous"
}

type publicLiveEdgePolicy struct {
	optionalDevice  bool
	allowQueryToken bool
	resolveActor    bool
	selectLimiter   func(set *live.LiveRateLimiterSet) *live.SlidingWindowLimiter
}

func (h *TrailLiveHandler) wrapPublicLiveRoute(
	policy publicLiveEdgePolicy,
	next func(*core.RequestEvent) error,
) func(*core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		// 1. Strip any spoofed internal headers coming from outside!
		e.Request.Header.Del("X-Internal-Secret")
		e.Request.Header.Del("X-Device-Hash")
		e.Request.Header.Del("X-Actor-Id")

		// 2. Validate X-Device-Token (or ?deviceToken= on /stream)
		deviceHash, err := live.ResolveRequestDeviceHash(
			e.Request,
			policy.optionalDevice,
			policy.allowQueryToken,
			"",
		)
		if err != nil {
			return e.JSON(http.StatusBadRequest, map[string]any{
				"message": "invalid_device_token",
			})
		}

		// 3. Enforce sharded in-RAM sliding-window rate limiter
		if policy.selectLimiter != nil {
			limiters := h.rateLimiters()
			if lim := policy.selectLimiter(limiters); lim != nil {
				rlKey := deviceHash
				if rlKey == "" {
					rlKey = clientRateLimitFallbackKey(e)
				}
				decision := lim.Check(rlKey, h.nowUTC())
				if !decision.Allowed {
					e.Response.Header().Set("Retry-After", strconv.Itoa(decision.RetryAfterSec))
					return e.JSON(http.StatusTooManyRequests, map[string]any{
						"message":       "rate_limit_exceeded",
						"retryAfterSec": decision.RetryAfterSec,
					})
				}
			}
		}

		// 4. Attach verified identity and lazily resolve ActivityPub actor ONLY where needed (/reports)
		if deviceHash != "" {
			e.Request.Header.Set("X-Device-Hash", deviceHash)
		}
		if policy.resolveActor {
			if actorID := ResolveOptionalActorID(e, h.ActorCache); actorID != "" {
				e.Request.Header.Set("X-Actor-Id", actorID)
			}
		}

		e.Request = markTrustedPublicLiveRequest(e.Request)
		return next(e)
	}
}

// VapidPublicKey serves GET /api/v1/live/push/vapid-public-key directly from Go.
func (h *TrailLiveHandler) VapidPublicKey(e *core.RequestEvent) error {
	disp := h.vapidDispatcher(e.App)
	pubKey, err := disp.PublicKey()
	if err != nil {
		return e.InternalServerError("Failed to initialize VAPID public key", err)
	}
	e.Response.Header().Set("Cache-Control", "public, max-age=3600")
	return e.JSON(http.StatusOK, map[string]any{
		"publicKey": pubKey,
	})
}

func (h *TrailLiveHandler) dispatchNativeSosPushIfPublic(
	app core.App,
	r *http.Request,
	dto SosAlertDto,
	pushTargets []PushTargetDto,
) bool {
	if !isTrustedPublicLiveRequest(r) {
		return false
	}
	if len(pushTargets) == 0 {
		return true
	}

	targets := make([]live.SosPushTarget, 0, len(pushTargets))
	for _, pt := range pushTargets {
		targets = append(targets, live.SosPushTarget{
			Endpoint:  pt.Endpoint,
			P256dh:    pt.P256dh,
			Auth:      pt.Auth,
			DistanceM: pt.DistanceM,
		})
	}

	disp := h.vapidDispatcher(app)
	disp.DispatchSosPushAsync(
		live.SosPushAlertInfo{
			ID:            dto.ID,
			TrailID:       dto.TrailID,
			Reason:        dto.Reason,
			Message:       dto.Message,
			RequesterName: dto.RequesterName,
		},
		targets,
		func(staleEndpoint string) {
			h.readyStore(app).DeletePushSub(staleEndpoint)
			if subRec, err := app.FindFirstRecordByData("push_subscriptions", "endpoint", staleEndpoint); err == nil && subRec != nil {
				_ = app.Delete(subRec)
			}
		},
	)
	return true
}

func registerTrailLiveRouterGroups(rtr *router.Router[*core.RequestEvent], handler *TrailLiveHandler) {
	// 1. Internal /live/* group (preserved for 100% dev compatibility with SvelteKit proxy)
	internal := rtr.Group("/live")
	internal.BindFunc(RequireLiveInternalProxy)

	internal.POST("/heartbeat", handler.Heartbeat)
	internal.DELETE("/heartbeat", handler.ClearHeartbeat)
	internal.GET("/trail/{id}/summary", handler.TrailSummary)
	internal.GET("/trail/{id}/environment", handler.TrailEnvironment)
	internal.GET("/street-preview", handler.StreetPreview)
	internal.GET("/env-hazards", handler.EnvHazardsSummary)
	internal.GET("/map/ancpi-status", func(e *core.RequestEvent) error {
		if err := verifyLiveInternalSecret(e); err != nil {
			return err
		}
		return handler.Ancpi.Status(e)
	})
	internal.POST("/reports", handler.CreateReport)
	internal.POST("/reports/{id}/vote", handler.VoteReport)
	internal.POST("/sos", handler.CreateSos)
	internal.POST("/sos/relay", handler.RelaySos)
	internal.PATCH("/sos/{id}", handler.UpdateSos)
	internal.POST("/sos/{id}/respond", handler.RespondSos)
	internal.POST("/push/subscribe", handler.PushSubscribe)
	internal.DELETE("/push/subscribe", handler.PushUnsubscribe)
	internal.POST("/groups", handler.CreateGroup)
	internal.GET("/groups/{code}", handler.GetGroup)
	internal.POST("/groups/{code}/join", handler.JoinGroup)
	internal.POST("/groups/{code}/ping", handler.PingGroup)
	internal.POST("/groups/{code}/leave", handler.LeaveGroup)
	internal.GET("/stream", handler.Stream)

	// 2. Public /api/v1/live/* group (routed directly from Caddy/Nginx -> Go with zero Node.js hop)
	pub := rtr.Group("/api/v1/live")

	reqDevice := publicLiveEdgePolicy{}
	pub.POST("/heartbeat", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.Heartbeat },
	}, handler.Heartbeat))
	pub.DELETE("/heartbeat", handler.wrapPublicLiveRoute(reqDevice, handler.ClearHeartbeat))

	pub.GET("/trail/{id}/summary", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		optionalDevice: true,
	}, handler.TrailSummary))
	pub.GET("/trail/{id}/environment", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		optionalDevice: true,
	}, handler.TrailEnvironment))
	pub.GET("/street-preview", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		optionalDevice: true,
	}, handler.StreetPreview))
	pub.GET("/env-hazards", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		optionalDevice: true,
	}, handler.EnvHazardsSummary))
	pub.GET("/map/ancpi-status", handler.Ancpi.Status)

	pub.POST("/reports", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		resolveActor:  true,
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.Reports },
	}, handler.CreateReport))
	pub.POST("/reports/{id}/vote", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.Votes },
	}, handler.VoteReport))

	pub.POST("/sos", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.Sos },
	}, handler.CreateSos))
	pub.POST("/sos/relay", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.SosRelay },
	}, handler.RelaySos))
	pub.PATCH("/sos/{id}", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.SosUpdate },
	}, handler.UpdateSos))
	pub.POST("/sos/{id}/respond", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.SosRespond },
	}, handler.RespondSos))

	pub.GET("/push/vapid-public-key", handler.VapidPublicKey)
	pub.POST("/push/subscribe", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.PushSubscribe },
	}, handler.PushSubscribe))
	pub.DELETE("/push/subscribe", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.PushSubscribe },
	}, handler.PushUnsubscribe))

	pub.POST("/groups", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.GroupCreate },
	}, handler.CreateGroup))
	pub.GET("/groups/{code}", handler.wrapPublicLiveRoute(reqDevice, handler.GetGroup))
	pub.POST("/groups/{code}/join", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.GroupJoin },
	}, handler.JoinGroup))
	pub.POST("/groups/{code}/ping", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		selectLimiter: func(s *live.LiveRateLimiterSet) *live.SlidingWindowLimiter { return s.GroupPing },
	}, handler.PingGroup))
	pub.POST("/groups/{code}/leave", handler.wrapPublicLiveRoute(reqDevice, handler.LeaveGroup))

	pub.GET("/stream", handler.wrapPublicLiveRoute(publicLiveEdgePolicy{
		optionalDevice:  true,
		allowQueryToken: true,
	}, handler.Stream))
}
