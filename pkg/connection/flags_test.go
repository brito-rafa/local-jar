package connection

import (
	"flag"
	"strings"
	"testing"
)

func TestDatabaseSettingsUseGenericEnvironmentAndCLIOverrides(t *testing.T) {
	t.Setenv("DB_URL", "example.test:9495")
	t.Setenv("DB_DISABLE_SSL", "true")
	var c Flags
	f := flag.NewFlagSet("test", flag.ContinueOnError)
	if err := c.Register(f); err != nil {
		t.Fatal(err)
	}
	if c.Endpoint != "quack:example.test:9495" || !c.DisableSSL {
		t.Fatalf("environment settings: %+v", c)
	}
	if err := f.Parse([]string{"-db-url=quack:other.test:9496", "-db-disable-ssl=false"}); err != nil {
		t.Fatal(err)
	}
	if c.Endpoint != "quack:other.test:9496" || c.DisableSSL {
		t.Fatalf("CLI overrides: %+v", c)
	}
}

func TestLocalDatabaseTransportDefaultsAndInvalidSettings(t *testing.T) {
	t.Setenv("DB_URL", "")
	t.Setenv("DB_DISABLE_SSL", "")
	var c Flags
	if err := c.Register(flag.NewFlagSet("test", flag.ContinueOnError)); err != nil {
		t.Fatal(err)
	}
	if c.Endpoint != "quack:127.0.0.1:9494" || !c.DisableSSL {
		t.Fatalf("local defaults: %+v", c)
	}
	t.Setenv("DB_DISABLE_SSL", "not-a-bool")
	if err := c.Register(flag.NewFlagSet("test", flag.ContinueOnError)); err == nil || !strings.Contains(err.Error(), "DB_DISABLE_SSL") {
		t.Fatalf("expected configuration error, got %v", err)
	}
}
