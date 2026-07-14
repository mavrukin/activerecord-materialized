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
  end

  describe ".candidates" do
    it "honors ARM_ONLY and otherwise returns every known adapter" do
      # ARM_ONLY restricts to the named adapter(s)...
      expect(described_class.candidates({ "ARM_ONLY" => "sqlite" }).map(&:key)).to eq([:sqlite])
      # ...unset returns all three, in a stable order
      expect(described_class.candidates({}).map(&:key)).to eq(%i[sqlite mysql postgres])
    end
  end

  describe "#available?" do
    it "is true for sqlite and false with a reason for an unreachable server" do
      # sqlite is always available in-process
      expect(described_class.profile(:sqlite, {}).available?).to be(true)
      # a dead TCP endpoint is unavailable, with the failure surfaced (never silent)
      dead = described_class.profile(:mysql, { "ARM_MYSQL_HOST" => "127.0.0.1", "ARM_MYSQL_PORT" => "1" })
      expect(dead.available?).to be(false)
      expect(dead.unavailable_reason).to be_a(String).and be_present
    end
  end
end
