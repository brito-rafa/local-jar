package connection

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/brito-rafa/local-jar/pkg/duck"
)

type Flags struct {
	Endpoint   string
	DisableSSL bool
}

func (c *Flags) Register(f *flag.FlagSet) error {
	endpoint := os.Getenv("DB_URL")
	if endpoint == "" {
		endpoint = "quack:127.0.0.1:9494"
	}
	if !strings.HasPrefix(endpoint, "quack:") {
		endpoint = "quack:" + endpoint
	}
	disableSSL := true // The local Compose service intentionally serves plain HTTP.
	if value := os.Getenv("DB_DISABLE_SSL"); value != "" {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("DB_DISABLE_SSL must be true or false")
		}
		disableSSL = parsed
	}
	f.StringVar(&c.Endpoint, "db-url", endpoint, "DuckDB Quack endpoint over TCP; token from DB_TOKEN")
	f.BoolVar(&c.DisableSSL, "db-disable-ssl", disableSSL, "Use plain HTTP for DuckDB (default for local Compose)")
	return nil
}

func (c Flags) Open() (*sql.DB, error) {
	return duck.OpenRemote(c.Endpoint, os.Getenv("DB_TOKEN"), c.DisableSSL)
}
