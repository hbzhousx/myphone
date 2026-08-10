// Package ota 提供 App 远程升级(OTA)服务:版本查询 + APK 下载。
//
// 元数据来自服务器上的 update.json(默认 /opt/myphone/update.json),APK 文件为
// myphone-latest.apk。部署时上传两者即可,无需数据库。
package ota

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"github.com/go-chi/chi/v5"
)

// UpdateInfo 描述一次可用的升级。
type UpdateInfo struct {
	Version   string `json:"version"`    // 语义化版本,如 "1.0.1"
	Build     int    `json:"build"`      // 构建号(versionCode),如 2
	URL       string `json:"url"`        // 相对下载路径,如 "/v1/ota/download"
	Notes     string `json:"notes"`      // 更新说明
	Mandatory bool   `json:"mandatory"`  // 是否强制更新
	SizeBytes int64  `json:"size_bytes"` // APK 大小(字节),可选
}

type Handler struct {
	// configDir 是 update.json 与 APK 所在目录(默认 /opt/myphone)。
	configDir string
	// apkFilename 是 APK 文件名(默认 myphone-latest.apk)。
	apkFilename string
}

// NewHandler 构造 OTA handler。configDir 为空时用 /opt/myphone。
func NewHandler(configDir string) *Handler {
	if configDir == "" {
		configDir = "/opt/myphone"
	}
	return &Handler{configDir: configDir, apkFilename: "myphone-latest.apk"}
}

func (h *Handler) RegisterRoutes(r chi.Router) {
	r.Get("/check", h.CheckUpdate)
	r.Get("/download", h.DownloadApk)
}

// updateJSONPath 返回 update.json 的绝对路径。
func (h *Handler) updateJSONPath() string {
	return h.configDir + "/update.json"
}

// apkPath 返回 APK 的绝对路径。
func (h *Handler) apkPath() string {
	return h.configDir + "/" + h.apkFilename
}

// loadUpdateInfo 读取 update.json;文件缺失或非法时返回错误。
func (h *Handler) loadUpdateInfo() (*UpdateInfo, error) {
	data, err := os.ReadFile(h.updateJSONPath())
	if err != nil {
		return nil, err
	}
	var info UpdateInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return nil, err
	}
	// 自动填充 APK 大小(若文件存在)。
	if info.SizeBytes == 0 {
		if fi, err := os.Stat(h.apkPath()); err == nil {
			info.SizeBytes = fi.Size()
		}
	}
	return &info, nil
}

// CheckUpdate 返回最新版本元数据。公开接口,无需鉴权(升级检查人人可用)。
func (h *Handler) CheckUpdate(w http.ResponseWriter, r *http.Request) {
	info, err := h.loadUpdateInfo()
	if err != nil {
		log.Printf("[OTA] load update.json: %v", err)
		http.Error(w, `{"error":"update info not available"}`, http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(info)
}

// DownloadApk 流式返回 APK 文件。
func (h *Handler) DownloadApk(w http.ResponseWriter, r *http.Request) {
	path := h.apkPath()
	if _, err := os.Stat(path); err != nil {
		log.Printf("[OTA] apk not found: %v", err)
		http.Error(w, `{"error":"apk not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", "attachment; filename="+h.apkFilename)
	http.ServeFile(w, r, path)
}
