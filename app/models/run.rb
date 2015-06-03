class Run < ActiveRecord::Base
  include PadawanRun
  include ActionView::Helpers::DateHelper

  belongs_to :user, touch: true
  belongs_to :category, touch: true
  belongs_to :run_file, primary_key: :digest, foreign_key: :run_file_digest
  has_one :game, through: :category
  has_many :segments, through: :run_file

  has_secure_token :claim_token

  after_create :refresh_from_run_file
  after_create :refresh_game
  after_destroy do |run|
    if run.run_file.present? && run.run_file.runs.where.not(id: run).empty?
      run.run_file.destroy
    end
  end

  @parse_cache = nil

  validates :run_file, presence: true
  validates_associated :run_file
  validates_with RunValidator

  scope :by_game, ->(game) { joins(:category).where(categories: {game_id: game}) }
  scope :by_category, ->(category) { where(category: category) }
  scope :nonempty, -> { where("time != 0") }
  scope :owned, -> { where.not(user: nil) }
  scope :unarchived, -> { where(archived: false) }
  scope :categorized, -> { joins(:category).where.not(categories: {name: nil}).joins(:game).where.not(games: {name: nil}) }

  class << self
    def programs
      [Urn, SplitterZ, TimeSplitTracker]
    end

    inheritance_column = :program
    def find_sti_class(program)
      Hash[RunFile.programs.map { |program| [program::Run.sti_name, program::Run] }][read_attribute(:program)]
    end

    alias_method :find10, :find
    # todo: rename this to `find` when APIv2 is removed
    def find36(id)
      find10(id.to_i(36))
    end
  end

  alias_method :id10, :id
  # todo: rename this to `id` when APIv2 is removed
  def id36
    id10.to_s(36)
  end

  def belongs_to?(user)
    user.present? && self.user == user
  end

  def time_since_upload
    time_ago_in_words(created_at).sub('about ', '')
  end

  def offset
    parse[:offset]
  end

  def attempts
    parse[:attempts]
  end

  def short?
    time < 20.minutes
  end

  def history
    parse[:history]
  end

  def parses?
    parse.present?
  end

  def parse
    return @parse_cache if @parse_cache.present?
    if RunFile.programs.map { |program| program::Run.sti_name }.include?(read_attribute(:program))
      [RunFile.programs[RunFile.programs.map { |program| program::Run.sti_name }.index(read_attribute(:program))]::Parser]
    else
      RunFile.programs.map { |program| program::Parser }
    end.each do |parser|
      result = parser.new.parse(file)
      next if result.blank?
      result[:program] = parser.name.sub('::Parser', '').downcase.to_sym

      assign_attributes(
        name: result[:name],
        program: result[:program],
        time: result[:splits].map { |split| split.duration }.sum.to_f,
        sum_of_best: result[:splits].map.all? do |split|
          split.best.duration.present?
        end && result[:splits].map do |split|
          split.best.duration
        end.sum.to_f
      )

      @parse_cache = result

      return result
    end
    {}
  rescue ArgumentError # comes from non UTF-8 files
    {
      error: "Your file wasn't UTF-8 encoded. Usually this means it didn't come straight from your program, but from some
      other source. If the file was sent to you by a friend, make sure the file as a whole is sent, not just the text inside it."
    }
  end

  def to_param
    id36
  end

  def path
    "/#{to_param}"
  end

  def best_known?
    category && time == category.best_known_run.try(:time)
  end

  def pb?
    user && category && self == user.pb_for(category)
  end

  def time
    read_attribute(:time).to_f
  end

  def file
    run_file.file
  end

  def refresh_from_run_file
    run_file.valid?
  end

  def refresh_game
    return if game.blank?
    game.delay.sync_with_srl
  end

  def has_golds?
    segments.any?(&:gold?)
  end

  def filename(download_program)
    extension = {'livesplit' => 'lss', 'urn' => 'json'}[download_program] || download_program
    "#{to_param}.#{extension}"
  end
end
