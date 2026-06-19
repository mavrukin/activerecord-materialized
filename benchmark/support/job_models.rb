# frozen_string_literal: true

module Job
  class CastInfo < ActiveRecord::Base
    self.table_name = "cast_info"

    belongs_to :name, foreign_key: :person_id, class_name: "Job::Name", inverse_of: :cast_infos
    belongs_to :title, foreign_key: :movie_id, class_name: "Job::Title", inverse_of: :cast_infos
    belongs_to :role_type, foreign_key: :role_id, class_name: "Job::RoleType", optional: true
    belongs_to :char_name, foreign_key: :person_role_id, class_name: "Job::CharName", optional: true

    has_many :movie_infos, foreign_key: :movie_id, primary_key: :movie_id,
                           class_name: "Job::MovieInfo", inverse_of: false
    has_many :aka_names, through: :name
  end

  class Name < ActiveRecord::Base
    self.table_name = "name"

    has_many :cast_infos, foreign_key: :person_id, class_name: "Job::CastInfo", inverse_of: :name
    has_many :aka_names, foreign_key: :person_id, class_name: "Job::AkaName", inverse_of: :name
  end

  class Title < ActiveRecord::Base
    self.table_name = "title"

    has_many :cast_infos, foreign_key: :movie_id, class_name: "Job::CastInfo", inverse_of: :title
    has_many :movie_companies, foreign_key: :movie_id, class_name: "Job::MovieCompany", inverse_of: :title
    has_many :movie_infos, foreign_key: :movie_id, class_name: "Job::MovieInfo", inverse_of: :title
    has_many :movie_info_idxs, foreign_key: :movie_id, class_name: "Job::MovieInfoIdx", inverse_of: :title
  end

  class MovieCompany < ActiveRecord::Base
    self.table_name = "movie_companies"

    belongs_to :title, foreign_key: :movie_id, class_name: "Job::Title", inverse_of: :movie_companies
    belongs_to :company_name, foreign_key: :company_id, class_name: "Job::CompanyName", inverse_of: :movie_companies
    belongs_to :company_type, class_name: "Job::CompanyType",
                              inverse_of: :movie_companies
  end

  class MovieInfo < ActiveRecord::Base
    self.table_name = "movie_info"

    belongs_to :title, foreign_key: :movie_id, class_name: "Job::Title", inverse_of: :movie_infos
    belongs_to :info_type, class_name: "Job::InfoType", inverse_of: :movie_infos
  end

  class MovieInfoIdx < ActiveRecord::Base
    self.table_name = "movie_info_idx"

    belongs_to :title, foreign_key: :movie_id, class_name: "Job::Title", inverse_of: :movie_info_idxs
    belongs_to :info_type, class_name: "Job::InfoType", inverse_of: :movie_info_idxs
  end

  class AkaName < ActiveRecord::Base
    self.table_name = "aka_name"

    belongs_to :name, foreign_key: :person_id, class_name: "Job::Name", inverse_of: :aka_names
  end

  class CharName < ActiveRecord::Base
    self.table_name = "char_name"
  end

  class CompanyName < ActiveRecord::Base
    self.table_name = "company_name"

    has_many :movie_companies, foreign_key: :company_id, class_name: "Job::MovieCompany", inverse_of: :company_name
  end

  class InfoType < ActiveRecord::Base
    self.table_name = "info_type"

    has_many :movie_infos, class_name: "Job::MovieInfo", inverse_of: :info_type
    has_many :movie_info_idxs, class_name: "Job::MovieInfoIdx", inverse_of: :info_type
  end

  class CompanyType < ActiveRecord::Base
    self.table_name = "company_type"

    has_many :movie_companies, class_name: "Job::MovieCompany", inverse_of: :company_type
  end

  class RoleType < ActiveRecord::Base
    self.table_name = "role_type"
  end

  MODELS = [
    CastInfo,
    Name,
    Title,
    MovieCompany,
    MovieInfo,
    AkaName,
    CharName,
    CompanyName,
    InfoType,
    CompanyType,
    RoleType,
    MovieInfoIdx
  ].freeze

  def self.register_models!
    MODELS.each { |model| ActiveRecord::Materialized::TableModelRegistry.register(model) }
  end
end
