package routes

import (
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

func isPrivateInstanceEnabled() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("PUBLIC_PRIVATE_INSTANCE")), "true")
}

func isAllowedThumbForCollection(col *core.Collection, thumb string) bool {
	if thumb == "" || col == nil {
		return false
	}
	if thumb == "100x100" || thumb == "0x0" {
		return true
	}
	for _, fld := range col.Fields {
		if ff, ok := fld.(*core.FileField); ok && slices.Contains(ff.Thumbs, thumb) {
			return true
		}
	}
	return false
}

// RequireCookieOrBearerAuth authenticates signed-in users via Authorization Bearer (JWT / wanderer_key_*) or pb_auth cookie.
func RequireCookieOrBearerAuth(e *core.RequestEvent) error {
	if e.Auth != nil {
		return e.Next()
	}
	if userRec := ResolveAuthUserRecordFromRequest(e.App, e.Request); userRec != nil {
		e.Auth = userRec
		return e.Next()
	}
	return e.UnauthorizedError("The request requires valid record authorization token.", nil)
}

// RequireSuperuserCookieOrBearerAuth requires PocketBase superuser authentication via header or pb_auth cookie.
func RequireSuperuserCookieOrBearerAuth(e *core.RequestEvent) error {
	if e.HasSuperuserAuth() {
		return e.Next()
	}
	tok := ExtractPocketBaseTokenFromRequest(e.Request)
	if tok != "" {
		if superRec, err := e.App.FindAuthRecordByToken(tok, core.TokenTypeAuth); err == nil && superRec != nil && superRec.IsSuperuser() {
			e.Auth = superRec
			return e.Next()
		}
	}
	return e.UnauthorizedError("The request requires valid superuser authorization token.", nil)
}

// RegisterZeroCopyFileDownloadHook intercepts PocketBase file downloads:
// 1. Enforces auth gate when PUBLIC_PRIVATE_INSTANCE=true (#1456).
// 2. Sets immutable Cache-Control (public on public instances, private on private instances).
// 3. Serves local disk files directly via http.ServeContent (*os.File -> kernel sendfile(2),
//    strong ETag, 304 Not Modified, and 206 Partial Content).
func RegisterZeroCopyFileDownloadHook(app core.App) {
	app.OnFileDownloadRequest().BindFunc(func(e *core.FileDownloadRequestEvent) error {
		privateMode := isPrivateInstanceEnabled()
		if privateMode {
			if e.Auth == nil && ResolveAuthUserRecordFromRequest(e.App, e.Request) == nil {
				return e.UnauthorizedError("Unauthorized", nil)
			}
			e.Response.Header().Set("Cache-Control", "private, max-age=86400, immutable")
		} else {
			e.Response.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}

		if e.ServedPath == "" {
			return e.Next()
		}

		cleanRel := filepath.Clean(filepath.FromSlash(e.ServedPath))
		if strings.HasPrefix(cleanRel, "..") {
			return e.BadRequestError("Invalid file path", nil)
		}
		localPath := filepath.Join(e.App.DataDir(), "storage", cleanRel)
		diskFile, err := os.Open(localPath)
		if err != nil {
			return e.Next()
		}
		defer diskFile.Close()

		info, statErr := diskFile.Stat()
		if statErr != nil || info.IsDir() {
			return e.Next()
		}

		e.Response.Header().Set("X-Content-Type-Options", "nosniff")
		e.Response.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, info.Size(), info.ModTime().UnixNano()))
		if ct := mime.TypeByExtension(filepath.Ext(e.ServedName)); ct != "" && e.Response.Header().Get("Content-Type") == "" {
			e.Response.Header().Set("Content-Type", ct)
		}

		http.ServeContent(e.Response, e.Request, e.ServedName, info.ModTime(), diskFile)
		return nil
	})
}

// RegisterPublicFilesAndRegionsRoutes mounts direct public /api/v1/files/{collection}/{record}/{filename}
// and /api/v1/regions/* routes on PocketBase's Go router.
func RegisterPublicFilesAndRegionsRoutes(se *core.ServeEvent) {
	serveLocalFileZeroCopy := func(e *core.RequestEvent, localPath, fname string, privateMode bool) (bool, error) {
		diskFile, openErr := os.Open(localPath)
		if openErr != nil {
			return false, nil
		}
		defer diskFile.Close()
		info, statErr := diskFile.Stat()
		if statErr != nil || info.IsDir() {
			return false, nil
		}
		if privateMode {
			e.Response.Header().Set("Cache-Control", "private, max-age=86400, immutable")
		} else {
			e.Response.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		e.Response.Header().Set("X-Content-Type-Options", "nosniff")
		e.Response.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, info.Size(), info.ModTime().UnixNano()))
		http.ServeContent(e.Response, e.Request, fname, info.ModTime(), diskFile)
		return true, nil
	}

	handlePublicFile := func(e *core.RequestEvent) error {
		col := strings.TrimSpace(e.Request.PathValue("collection"))
		recID := strings.TrimSpace(e.Request.PathValue("record"))
		fname := strings.TrimSpace(e.Request.PathValue("filename"))
		if col == "" || len(recID) != 15 || fname == "" || strings.Contains(fname, "..") || strings.ContainsAny(fname, `/\`) {
			return e.BadRequestError("Invalid file parameters", nil)
		}

		privateMode := isPrivateInstanceEnabled()
		if privateMode {
			if e.Auth == nil && ResolveAuthUserRecordFromRequest(e.App, e.Request) == nil {
				return e.UnauthorizedError("Unauthorized", nil)
			}
		}

		collectionObj, err := e.App.FindCachedCollectionByNameOrId(col)
		if err != nil || collectionObj == nil {
			return e.NotFoundError("Collection not found", nil)
		}

		thumb := strings.TrimSpace(e.Request.URL.Query().Get("thumb"))
		if thumb != "" && !isAllowedThumbForCollection(collectionObj, thumb) {
			thumb = ""
		}

		hasProtectedField := false
		for _, fld := range collectionObj.Fields {
			if ff, ok := fld.(*core.FileField); ok && ff.Protected {
				hasProtectedField = true
				break
			}
		}

		if !hasProtectedField && !collectionObj.IsView() {
			if thumb == "" {
				localPath := filepath.Join(e.App.DataDir(), "storage", collectionObj.Id, recID, fname)
				if ok, err := serveLocalFileZeroCopy(e, localPath, fname, privateMode); ok || err != nil {
					return err
				}
			} else {
				localThumb := filepath.Join(e.App.DataDir(), "storage", collectionObj.Id, recID, "thumbs_"+fname, thumb+"_"+fname)
				if ok, err := serveLocalFileZeroCopy(e, localThumb, fname, privateMode); ok || err != nil {
					return err
				}
			}
		}

		fSys, fsErr := e.App.NewFilesystem()
		if fsErr != nil {
			return e.InternalServerError("Failed to initialize filesystem", fsErr)
		}
		defer fSys.Close()

		origKey := collectionObj.Id + "/" + recID + "/" + fname
		servedKey := origKey
		if thumb != "" {
			thumbKey := collectionObj.Id + "/" + recID + "/thumbs_" + fname + "/" + thumb + "_" + fname
			if exists, _ := fSys.Exists(thumbKey); !exists {
				_ = fSys.CreateThumb(origKey, thumbKey, thumb)
			}
			if exists, _ := fSys.Exists(thumbKey); exists {
				servedKey = thumbKey
			}
		}

		localPath := filepath.Join(e.App.DataDir(), "storage", filepath.FromSlash(servedKey))
		if ok, err := serveLocalFileZeroCopy(e, localPath, fname, privateMode); ok || err != nil {
			return err
		}

		if privateMode {
			e.Response.Header().Set("Cache-Control", "private, max-age=86400, immutable")
		} else {
			e.Response.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		return fSys.Serve(e.Response, e.Request, servedKey, fname)
	}

	se.Router.GET("/api/v1/files/{collection}/{record}/{filename}", handlePublicFile)
	se.Router.HEAD("/api/v1/files/{collection}/{record}/{filename}", handlePublicFile)

	pubRegions := se.Router.Group("/api/v1/regions")
	pubRegions.BindFunc(RequireCookieOrBearerAuth)
	pubRegions.GET("", RegionsList)
	pubRegions.GET("/{id}/download", RegionArchiveDownload)
	pubRegions.HEAD("/{id}/download", RegionArchiveDownload)
	pubRegions.GET("/{id}/download-dem", RegionArchiveDownloadDem)
	pubRegions.HEAD("/{id}/download-dem", RegionArchiveDownloadDem)

	se.Router.GET("/api/v1/regions/{id}/geometry", RegionGeometryGet).BindFunc(RequireSuperuserCookieOrBearerAuth)
}
