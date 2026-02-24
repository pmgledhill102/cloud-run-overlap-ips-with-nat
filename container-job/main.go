package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func main() {
	targetURL := os.Getenv("TARGET_URL")
	if targetURL == "" {
		fmt.Fprintln(os.Stderr, "TARGET_URL environment variable is required")
		os.Exit(1)
	}

	fmt.Printf("Requesting %s ...\n", targetURL)
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(targetURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	fmt.Printf("Status: %d\nBody:\n%s\n", resp.StatusCode, string(body))
}
