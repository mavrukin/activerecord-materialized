# frozen_string_literal: true

# Generates a JOB-style SQLite database with enough data to demonstrate
# slow multi-join analytical queries on SQLite.
#
# Based on the Join Order Benchmark (JOB) schema from:
# https://github.com/gregrahn/join-order-benchmark
#
# Usage: ruby benchmark/scripts/generate_job_database.rb [path_to_db]

require "sqlite3"
require "securerandom"
require "fileutils"

ROOT = File.expand_path("../..", __dir__)
DEFAULT_DB_PATH = File.join(ROOT, "benchmark", "fixtures", "job.sqlite")
DB_PATH = ENV["JOB_DB"] || (ARGV.first if ARGV.first&.end_with?(".sqlite")) || DEFAULT_DB_PATH
SCALE = (ENV["JOB_SCALE"] || "medium").to_s

SCALES = {
  "small" => { titles: 2_000, names: 4_000, cast_info: 40_000, companies: 400, mc_per_title: 2, mi_per_title: 3 },
  "medium" => { titles: 8_000, names: 15_000, cast_info: 180_000, companies: 1_200, mc_per_title: 2, mi_per_title: 3 },
  "large" => { titles: 20_000, names: 40_000, cast_info: 500_000, companies: 3_000, mc_per_title: 3, mi_per_title: 4 },
  "xlarge" => { titles: 50_000, names: 100_000, cast_info: 2_000_000, companies: 8_000, mc_per_title: 4, mi_per_title: 5 },
  "stress" => { titles: 80_000, names: 160_000, cast_info: 8_000_000, companies: 12_000, mc_per_title: 8, mi_per_title: 6 }
}.freeze

config = SCALES.fetch(SCALE) { SCALES["medium"] }

FileUtils.mkdir_p(File.dirname(DB_PATH))
File.delete(DB_PATH) if File.exist?(DB_PATH)

db = SQLite3::Database.new(DB_PATH)
db.execute("PRAGMA journal_mode = WAL")
db.execute("PRAGMA synchronous = NORMAL")

schema = File.read(File.join(ROOT, "benchmark", "fixtures", "job_schema.sql"))
schema.split(/;\s*\n/).each do |statement|
  next if statement.strip.empty?

  db.execute(statement)
end

puts "Generating JOB-style dataset (#{SCALE} scale) at #{DB_PATH}..."

def insert_rows(db, table, columns, rows)
  placeholders = (["?"] * columns.size).join(", ")
  sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})"
  db.transaction do
    rows.each_slice(500) { |batch| batch.each { |row| db.execute(sql, row) } }
  end
end

# Lookup tables
insert_rows(db, "kind_type", %w[id kind], [[1, "movie"], [2, "tv series"], [3, "video game"]])
insert_rows(db, "role_type", %w[id role], [[1, "actor"], [2, "actress"], [3, "director"], [4, "producer"]])
insert_rows(db, "company_type", %w[id kind], [[1, "production companies"], [2, "distributors"]])
insert_rows(db, "info_type", %w[id info], [
  [1, "top 250 rank"], [2, "release dates"], [3, "runtime"], [4, "budget"]
])
insert_rows(db, "link_type", %w[id link], [[1, "sequel"], [2, "remake"]])
insert_rows(db, "comp_cast_type", %w[id kind], [[1, "cast"], [2, "crew"]])

titles = config[:titles]
names_count = config[:names]
cast_count = config[:cast_info]
companies_count = config[:companies]

title_rows = (1..titles).map do |id|
  year = 1980 + (id % 45)
  [id, "Movie Title #{id}", nil, 1, year, id * 10, nil, nil, nil, nil, nil, SecureRandom.hex(16)]
end
insert_rows(db, "title", %w[id title imdb_index kind_id production_year imdb_id phonetic_code episode_of_id season_nr episode_nr series_years md5sum], title_rows)

name_rows = (1..names_count).map do |id|
  gender = id.even? ? "f" : "m"
  [id, "Person #{id}", nil, id, gender, nil, nil, nil, SecureRandom.hex(16)]
end
insert_rows(db, "name", %w[id name imdb_index imdb_id gender name_pcode_cf name_pcode_nf surname_pcode md5sum], name_rows)

char_rows = (1..(names_count / 2)).map do |id|
  [id, "Character #{id}", nil, id, nil, nil, SecureRandom.hex(16)]
end
insert_rows(db, "char_name", %w[id name imdb_index imdb_id name_pcode_nf surname_pcode md5sum], char_rows)

company_rows = (1..companies_count).map do |id|
  country = case id % 5
            when 0 then "[ru]"
            when 1 then "[us]"
            when 2 then "[gb]"
            else "[de]"
            end
  [id, "Company #{id}", country, id, nil, nil, SecureRandom.hex(16)]
end
insert_rows(db, "company_name", %w[id name country_code imdb_id name_pcode_nf name_pcode_sf md5sum], company_rows)

keyword_rows = (1..500).map { |id| [id, "keyword-#{id}", nil] }
insert_rows(db, "keyword", %w[id keyword phonetic_code], keyword_rows)

cast_rows = []
(1..cast_count).each do |id|
  movie_id = (id % titles) + 1
  person_id = (id % names_count) + 1
  role_id = person_id.even? ? 2 : 1
  person_role_id = (id % char_rows.size) + 1
  note = case id % 7
         when 0 then "(voice) (uncredited)"
         when 1 then "(voice: Japanese version)"
         when 2 then "(voice: English version)"
         when 3 then "(co-production)"
         else "standard role"
         end
  cast_rows << [id, person_id, movie_id, person_role_id, note, id % 20, role_id]
end
insert_rows(db, "cast_info", %w[id person_id movie_id person_role_id note nr_order role_id], cast_rows)

mc_rows = []
mc_per_title = config[:mc_per_title]
(1..(titles * mc_per_title)).each do |id|
  movie_id = ((id - 1) % titles) + 1
  company_id = ((id * 3) % companies_count) + 1
  note = case id % 4
         when 0 then "Metro-Goldwyn-Mayer Pictures (co-production)"
         when 1 then "Studio presents feature"
         when 2 then "Metro-Goldwyn-Mayer Pictures"
         else "independent"
         end
  mc_rows << [id, movie_id, company_id, 1, note]
end
insert_rows(db, "movie_companies", %w[id movie_id company_id company_type_id note], mc_rows)

mi_idx_rows = []
(1..titles).each do |movie_id|
  rank = movie_id <= 250 ? movie_id.to_s : "999"
  mi_idx_rows << [movie_id, movie_id, 1, rank, nil]
end
insert_rows(db, "movie_info_idx", %w[id movie_id info_type_id info note], mi_idx_rows)

mi_rows = []
mi_per_title = config[:mi_per_title]
(1..(titles * mi_per_title)).each do |id|
  movie_id = ((id - 1) % titles) + 1
  mi_rows << [id, movie_id, 2, "200#{movie_id % 10}-0#{(movie_id % 9) + 1}-15", nil]
end
insert_rows(db, "movie_info", %w[id movie_id info_type_id info note], mi_rows)

aka_name_rows = (1..names_count).map { |id| [id, id, "Aka Person #{id}", nil, nil, nil, nil, SecureRandom.hex(16)] }
insert_rows(db, "aka_name", %w[id person_id name imdb_index name_pcode_cf name_pcode_nf surname_pcode md5sum], aka_name_rows)

indexes = File.read(File.join(ROOT, "benchmark", "fixtures", "job_indexes.sql"))
indexes.split(/;\s*\n/).each do |statement|
  next if statement.strip.empty?

  db.execute(statement)
end

db.execute("ANALYZE")

stats = {
  "title" => titles,
  "name" => names_count,
  "cast_info" => cast_count,
  "movie_companies" => mc_rows.size
}

puts "Done. Row counts:"
stats.each { |table, count| puts "  #{table}: #{count}" }
File.write("#{DB_PATH}.scale", SCALE)
puts "Scale marker written to #{DB_PATH}.scale"
puts "Database written to #{DB_PATH}"
