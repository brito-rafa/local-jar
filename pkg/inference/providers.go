package inference

import (
	"context"

	"github.com/ardanlabs/kronk/sdk/kronk/model"
)

// Embedder and ChatModel allow tests to supply model callbacks without loading Kronk.
type Embedder interface {
	Embeddings(context.Context, model.D) (model.EmbedReponse, error)
	Unload(context.Context) error
}

type ChatModel interface {
	ChatStreaming(context.Context, model.D) (<-chan model.ChatResponse, error)
	Unload(context.Context) error
}

// OpenEmbedding loads a local Kronk model with the requested embedding concurrency.
func OpenEmbedding(source string, workers int) (Embedder, error) {
	p, _, err := Install(source, "")
	if err != nil {
		return nil, err
	}
	return New(p, model.WithNSeqMax(workers))
}

// OpenChat loads a local Kronk chat model.
func OpenChat(source string) (ChatModel, error) {
	p, _, err := Install(source, "")
	if err != nil {
		return nil, err
	}
	return New(p)
}
