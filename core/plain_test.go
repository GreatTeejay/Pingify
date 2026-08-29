package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Leaving the setting out has to mean the cipher stays on, or every tunnel
// written before it existed would quietly stop encrypting on upgrade.
func TestEncryptionIsOnUnlessTurnedOff(t *testing.T) {
	yes, no := true, false
	for _, c := range []struct {
		name string
		cfg  Config
		want bool
	}{
		{"a config that predates the setting", Config{}, true},
		{"asked for explicitly", Config{Encrypt: &yes}, true},
		{"turned off explicitly", Config{Encrypt: &no}, false},
	} {
		if got := c.cfg.encrypted(); got != c.want {
			t.Errorf("%s: encrypted() = %v, want %v", c.name, got, c.want)
		}
	}
}

// And it has to survive the config file, because both ends read it from one
// and a tunnel where only one end encrypts does not come up at all.
func TestTheConfigFileCarriesTheChoice(t *testing.T) {
	const base = `[tunnel]
name = "t"
role = "server"
mode = "forward"

[security]
token = "a shared secret between two servers"

[forward]
ports = ["443"]

[transport]
type = "tcp"
listen = "0.0.0.0:9443"
`

	for _, c := range []struct {
		name string
		add  string
		want bool
	}{
		{"absent means encrypted", "", true},
		{"off", "encrypt = false\n", false},
		{"on", "encrypt = true\n", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := filepath.Join(t.TempDir(), "t.toml")
			if err := os.WriteFile(f, []byte(base+c.add), 0600); err != nil {
				t.Fatal(err)
			}
			cfg, err := loadConfig(f)
			if err != nil {
				t.Fatal(err)
			}
			cfg.applyDefaults()
			if got := cfg.encrypted(); got != c.want {
				t.Fatalf("encrypted() = %v, want %v", got, c.want)
			}
		})
	}
}
