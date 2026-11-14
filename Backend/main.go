package main

import (
	"fmt"
	"net/http"

    "github.com/az-black/app-pengompres-gambar-pdf/internal/handler"

)



func main() {

    http.HandleFunc("/compress", handler.CompressHandler)
    http.HandleFunc("/pdf-workflow", handler.PdfWorkflowHandler)
    http.HandleFunc("/health", handler.HealthHandler)
    http.HandleFunc("/engine/warmup", handler.EngineWarmupHandler)

    fmt.Println("Server berjalan di http://localhost:8080")

    err := http.ListenAndServe(":8080", nil)

    if err != nil {
        fmt.Println(err)
    }

}


