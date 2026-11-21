package chat

import (
	"strings"
	"testing"
)

func TestLocalChatRejectsRemoteInferenceFlags(t *testing.T) {
	for _, name := range []string{"remote-chat", "remote-embedding", "remote-chat-model", "remote-embedding-model", "chat-url", "embedding-url"} {
		if err := Run([]string{"-" + name + "=example.test"}); err == nil || !strings.Contains(err.Error(), "flag provided but not defined") {
			t.Fatalf("%s: expected unsupported flag, got %v", name, err)
		}
	}
}
