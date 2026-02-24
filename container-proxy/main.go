package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	targetURL := os.Getenv("TARGET_URL")
	if targetURL == "" {
		fmt.Fprintln(os.Stderr, "TARGET_URL environment variable is required")
		os.Exit(1)
	}

	hostname, _ := os.Hostname()
	client := &http.Client{Timeout: 15 * time.Second}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp, err := client.Get(targetURL)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			fmt.Fprintf(w, "ERROR proxying to %s: %v\nHostname: %s\nService: %s\n",
				targetURL, err, hostname, os.Getenv("K_SERVICE"))
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)

		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "Proxy OK\nHostname: %s\nService: %s\nTarget: %s\nTarget status: %d\nTarget body:\n%s\n",
			hostname, os.Getenv("K_SERVICE"), targetURL, resp.StatusCode, string(body))
	})

	fmt.Printf("Listening on port %s, proxying to %s\n", port, targetURL)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
