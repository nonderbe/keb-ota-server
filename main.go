package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	listenAddr  = ":8080"
	firmwareDir = "/var/www/firmware"
	baseURL     = "https://firmware.local-share.com"
)

var adminToken = os.Getenv("ADMIN_TOKEN")

type Manifest struct {
	Version    string    `json:"version"`
	URL        string    `json:"url"`
	MD5        string    `json:"md5"`
	Mandatory  bool      `json:"mandatory"`
	Notes      string    `json:"notes"`
	ReleasedAt time.Time `json:"released_at"`
}

type CheckResponse struct {
	UpdateAvailable bool   `json:"update_available"`
	Version         string `json:"version,omitempty"`
	URL             string `json:"url,omitempty"`
	MD5             string `json:"md5,omitempty"`
	Mandatory       bool   `json:"mandatory,omitempty"`
	Notes           string `json:"notes,omitempty"`
}

type CheckinPayload struct {
	DeviceID string `json:"device_id"`
	Version  string `json:"version"`
	Channel  string `json:"channel"`
	MAC      string `json:"mac"`
}

type ReleasePayload struct {
	Channel   string `json:"channel"`
	Version   string `json:"version"`
	MD5       string `json:"md5"`
	Mandatory bool   `json:"mandatory"`
	Notes     string `json:"notes"`
}

func main() {
	if adminToken == "" {
		log.Fatal("ADMIN_TOKEN environment variable is not set")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/ota/check", handleCheck)
	mux.HandleFunc("/ota/checkin", handleCheckin)
	mux.HandleFunc("/admin/release", handleRelease)
	log.Printf("OTA server listening on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}

func handleCheck(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	version := r.URL.Query().Get("version")
	channel := sanitizeChannel(r.URL.Query().Get("channel"))
	manifest, err := loadManifest(channel)
	if err != nil {
		writeJSON(w, CheckResponse{UpdateAvailable: false})
		return
	}
	resp := CheckResponse{UpdateAvailable: false}
	if newerThan(manifest.Version, version) {
		resp = CheckResponse{
			UpdateAvailable: true,
			Version:         manifest.Version,
			URL:             manifest.URL,
			MD5:             manifest.MD5,
			Mandatory:       manifest.Mandatory,
			Notes:           manifest.Notes,
		}
	}
	writeJSON(w, resp)
	log.Printf("[check] device=%s ver=%s chan=%s update=%v",
		r.URL.Query().Get("device_id"), version, channel, resp.UpdateAvailable)
}

func handleCheckin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var p CheckinPayload
	json.NewDecoder(r.Body).Decode(&p)
	log.Printf("[checkin] device=%s mac=%s ver=%s chan=%s", p.DeviceID, p.MAC, p.Version, p.Channel)
	w.WriteHeader(http.StatusNoContent)
}

func handleRelease(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.Header.Get("X-Admin-Token") != adminToken {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var p ReleasePayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	p.Channel = sanitizeChannel(p.Channel)
	m := Manifest{
		Version:    p.Version,
		URL:        fmt.Sprintf("%s/files/%s/killbill-%s.bin", baseURL, p.Channel, p.Version),
		MD5:        p.MD5,
		Mandatory:  p.Mandatory,
		Notes:      p.Notes,
		ReleasedAt: time.Now().UTC(),
	}
	if err := saveManifest(p.Channel, m); err != nil {
		http.Error(w, "failed to save manifest", http.StatusInternalServerError)
		return
	}
	log.Printf("[release] chan=%s ver=%s mandatory=%v", p.Channel, p.Version, p.Mandatory)
	writeJSON(w, map[string]bool{"ok": true})
}

func loadManifest(channel string) (*Manifest, error) {
	data, err := os.ReadFile(filepath.Join(firmwareDir, channel, "manifest.json"))
	if err != nil {
		return nil, err
	}
	var m Manifest
	return &m, json.Unmarshal(data, &m)
}

func saveManifest(channel string, m Manifest) error {
	data, _ := json.MarshalIndent(m, "", "  ")
	return os.WriteFile(filepath.Join(firmwareDir, channel, "manifest.json"), data, 0644)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func sanitizeChannel(c string) string {
	if c == "beta" {
		return "beta"
	}
	return "stable"
}

func newerThan(candidate, current string) bool {
	return semver(candidate) > semver(current)
}

func semver(v string) int64 {
	v = strings.SplitN(v, "-", 2)[0]
	parts := strings.SplitN(v, ".", 3)
	var n [3]int64
	for i, p := range parts {
		if i >= 3 {
			break
		}
		n[i], _ = strconv.ParseInt(p, 10, 64)
	}
	return n[0]*1_000_000 + n[1]*1_000 + n[2]
}
