package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/go-chi/chi/v5"
)

// AttachmentsHandler 提供附件（图片/视频/文件）的服务器中转存储。
//
// 与 Signal 的附件 CDN 同理：客户端把 **已经端到端加密的密文** 上传到这里，
// 服务器只负责存储与转发，**绝不解密**文件内容（E2EE 不被破坏）。密钥走棘轮
// 加密的 chatMessage 直达接收方，服务器不接触。
//
// 密文文件存于本地磁盘（MYPHONE_ATTACHMENT_DIR，默认 /opt/myphone/attachments），
// 文件名即随机 attachment_id，不保留扩展名/元数据。
type AttachmentsHandler struct {
	dir string
}

func NewAttachmentsHandler(dir string) *AttachmentsHandler {
	if dir == "" {
		dir = "/opt/myphone/attachments"
	}
	return &AttachmentsHandler{dir: dir}
}

// Upload 接收客户端上传的密文，落盘并返回 attachment_id + 下载 URL。
func (h *AttachmentsHandler) Upload(w http.ResponseWriter, r *http.Request) {
	if err := os.MkdirAll(h.dir, 0o750); err != nil {
		http.Error(w, `{"error":"storage unavailable"}`, http.StatusInternalServerError)
		return
	}

	// multipart/form-data，字段名 file（密文字节）。
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, `{"error":"invalid multipart"}`, http.StatusBadRequest)
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		http.Error(w, `{"error":"missing file"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()

	id := newAttachmentID()
	dest := filepath.Join(h.dir, id)
	out, err := os.Create(dest)
	if err != nil {
		http.Error(w, `{"error":"storage write failed"}`, http.StatusInternalServerError)
		return
	}
	defer out.Close()
	n, err := io.Copy(out, file)
	if err != nil {
		os.Remove(dest)
		http.Error(w, `{"error":"storage write failed"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]any{
		"attachment_id": id,
		"url":           "/v1/attachments/" + id,
		"size_bytes":    n,
	})
}

// Download 流式返回密文文件（服务器不见明文）。
func (h *AttachmentsHandler) Download(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if id == "" || len(id) != 64 {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	path := filepath.Join(h.dir, id)
	// ServeFile 自动处理 stat/Content-Length/Range；文件缺失时返回 404。
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeFile(w, r, path)
}

func newAttachmentID() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	return hex.EncodeToString(b)
}
