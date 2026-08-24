package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "hello from %s (path %s)\n", podName(), r.URL.Path)
	})
	http.HandleFunc("/api", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"app":"k8s-testapp","pod":%q}`, podName())
	})
	addr := ":8080"
	fmt.Println("k8s-testapp listening on", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func podName() string {
	if n := os.Getenv("POD_NAME"); n != "" {
		return n
	}
	return os.Getenv("HOSTNAME")
}
