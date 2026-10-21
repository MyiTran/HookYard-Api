module Pagination
  extend ActiveSupport::Concern

  MAX_PAGE_SIZE = 100

  PAGY_KEYS_TRANSFORMER = {
    limit: :page_size,
    page: :page_number,
    count: :total_count,
    prev: :prev_page,
    next: :next_page,
    last: :last_page
  }.freeze

  def paginate(collection)
    pagy(collection, page: page_number, limit: page_size)
  end

  def paginate_array(array)
    pagy_array(array, page: page_number, limit: page_size)
  end

  def paginate_meta(pagy)
    pagy_metadata(pagy).transform_keys { |key| PAGY_KEYS_TRANSFORMER[key] }
  end

  def page_number
    positive_integer(page_params[:number]) || 1
  end

  def page_size
    requested = positive_integer(page_params[:size])

    requested ? [requested, MAX_PAGE_SIZE].min : Pagy::DEFAULT[:limit]
  end

  def page_params
    params[:page].is_a?(ActionController::Parameters) ? params[:page] : ActionController::Parameters.new
  end

  def positive_integer(value)
    return unless value.is_a?(Integer) || value.is_a?(String)
    return unless value.to_s.match?(/\A\d+\z/)

    number = value.to_i
    number if number.positive?
  end
end
