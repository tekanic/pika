package main

import (
	"encoding/json"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
)

func main() {
	if p := os.Getenv("GOMAXPROCS"); p != "" {
		if n, err := strconv.Atoi(p); err == nil && n > 0 {
			runtime.GOMAXPROCS(n)
		}
	}
	r := chi.NewRouter()

	// Static route
	r.Get("/bench/static", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	// JSON route
	r.Get("/bench/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"status": "ok",
			"ts":     time.Now().Unix(),
		})
	})

	// Validated params route (POST with JSON body)
	r.Post("/bench", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Name  string `json:"name"`
			Count int    `json:"count"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
			http.Error(w, `{"error":"invalid"}`, http.StatusUnprocessableEntity)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"echo": body.Name,
			"n":    body.Count,
		})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "4000"
	}
	_ = strconv.Itoa(0)
	http.ListenAndServe(":"+port, r)
}
