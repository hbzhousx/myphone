package discovery

import (
	"encoding/json"
	"net/http"

	"github.com/lib/pq"
	"github.com/myphone/server/internal/models"
)

type ContactDiscovery struct{ db *models.DB }

func NewContactDiscovery(db *models.DB) *ContactDiscovery {
	return &ContactDiscovery{db: db}
}

type DiscoverRequest struct {
	PhoneHashes []string `json:"phone_hashes"`
}

func (cd *ContactDiscovery) Discover(w http.ResponseWriter, r *http.Request) {
	var req DiscoverRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if len(req.PhoneHashes) == 0 {
		json.NewEncoder(w).Encode(map[string]interface{}{"matches": []interface{}{}})
		return
	}
	rows, err := cd.db.Query(
		`SELECT id, phone_hash, display_name, identity_public_key FROM users WHERE phone_hash = ANY($1)`,
		pq.Array(req.PhoneHashes),
	)
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type Match struct {
		UserID                 string `json:"id"`
		PhoneHash              string `json:"phone_hash"`
		DisplayName            string `json:"display_name"`
		PublicKeyFingerprint   string `json:"public_key_fingerprint"`
	}
	var matches []Match
	for rows.Next() {
		var m Match
		if err := rows.Scan(&m.UserID, &m.PhoneHash, &m.DisplayName, &m.PublicKeyFingerprint); err != nil {
			continue
		}
		matches = append(matches, m)
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"matches": matches})
}
