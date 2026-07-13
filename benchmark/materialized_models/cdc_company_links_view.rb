# frozen_string_literal: true

# A CDC-fed materialized view: its changes arrive through the ingestion API
# (+change_source :none+), NOT ActiveRecord commit callbacks — so a raw SQL write to
# movie_companies is reflected only once relayed via
# +ActiveRecord::Materialized.ingest_change+. It counts company links per company
# type; the GROUP BY key (+company_type_id+) lives on the written row, so a single
# ingested change scopes maintenance to exactly one partition. Refreshes +:immediate+
# so the demo applies a relayed change synchronously and shows the result at once.
class CdcCompanyLinksView < ActiveRecord::Materialized::View
  extend ActiveRecord::Materialized::QueryExpressions

  self.table_name = "mv_cdc_company_links"

  change_source :none
  refresh_on_change :immediate

  materialized_from do
    movie_company = Job::MovieCompany.arel_table
    Job::MovieCompany.group(:company_type_id).select(
      movie_company[:company_type_id],
      count_all_as(as: :link_count)
    )
  end

  depends_on :movie_companies
end
