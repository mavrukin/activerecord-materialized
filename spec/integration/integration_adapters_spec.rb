# frozen_string_literal: true

require "spec_helper"
require_relative "adapters"

# Unit-level checks for the DB matrix registry — no real MySQL/Postgres needed.
RSpec.describe IntegrationAdapters do
  describe ".connection_config" do
    it "builds sqlite in-process, a discrete-env config, and a URL config" do
      # sqlite is always in-process
      expect(described_class.connection_config(:sqlite, {})).to eq(adapter: "sqlite3", database: ":memory:")

      # discrete ARM_MYSQL_* env => trilogy adapter with those parts
      mysql_env = {
        "ARM_MYSQL_HOST" => "db.example", "ARM_MYSQL_PORT" => "3307",
        "ARM_MYSQL_USER" => "root", "ARM_MYSQL_PASSWORD" => "secret", "ARM_MYSQL_DATABASE" => "arm_test"
      }
      expect(described_class.connection_config(:mysql, mysql_env))
        .to include(adapter: "trilogy", host: "db.example", port: 3307, database: "arm_test")

      # a URL wins over discrete parts and maps to the pg adapter
      pg = described_class.connection_config(:postgres, { "ARM_PG_URL" => "postgres://u:p@pghost:5433/arm_pg" })
      expect(pg).to include(adapter: "postgresql", host: "pghost", port: 5433, database: "arm_pg", username: "u")
    end

    it "tolerates a blank port and drops blank parts rather than emitting empty strings" do
      # a blank port falls back to the adapter default (no Integer("") crash)
      blank_port = described_class.connection_config(:mysql, { "ARM_MYSQL_HOST" => "h", "ARM_MYSQL_PORT" => "" })
      expect(blank_port).to include(host: "h", port: 3306)
      # a URL without a database path does not leave database: ""
      no_db = described_class.connection_config(:postgres, { "ARM_PG_URL" => "postgres://u@h:5433" })
      expect(no_db).not_to have_key(:database)
    end
  end

  describe ".candidates" do
    it "honors ARM_ONLY, flags named adapters required, and rejects unknown names" do
      # ARM_ONLY restricts to the named adapter(s), which become required...
      only = described_class.candidates({ "ARM_ONLY" => "sqlite" })
      expect(only.map(&:key)).to eq([:sqlite])
      expect(only.first.required?).to be(true)
      # ...unset returns all three, none required (local "run what I have")
      expect(described_class.candidates({}).map(&:required?)).to eq([false, false, false])
      # a typo can't silently test nothing — it raises
      expect { described_class.candidates({ "ARM_ONLY" => "postgresql" }) }
        .to raise_error(IntegrationAdapters::ConfigError, /unknown ARM_ONLY/)
    end
  end

  describe "#available?" do
    it "is sqlite-true, and false-with-a-reason for a dead server or a malformed port" do
      # sqlite is always available in-process
      expect(described_class.profile(:sqlite, {}).available?).to be(true)
      # a dead TCP endpoint is unavailable, with the failure surfaced (never silent)
      dead = described_class.profile(:mysql, { "ARM_MYSQL_HOST" => "127.0.0.1", "ARM_MYSQL_PORT" => "1" })
      expect(dead.available?).to be(false)
      # a non-numeric port is reported (not raised) as unavailable
      bad_port = described_class.profile(:mysql, { "ARM_MYSQL_HOST" => "h", "ARM_MYSQL_PORT" => "nope" })
      expect(bad_port.unavailable_reason).to include("non-numeric port")
    end
  end
end
