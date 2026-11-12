module Admin
  class SupportAccountsQuery < ApplicationQuery
    ROLES = %w[admin support none].freeze

    ORDERS = {
      'created_desc' => { created_at: :desc, id: :desc },
      'created_asc' => { created_at: :asc, id: :asc },
      'email_asc' => { email: :asc }
    }.freeze

    DEFAULT_ORDER = 'created_desc'

    def call(scope = User.none, **params)
      scope = filter(scope, :by_search, params[:q])
      scope = by_role(scope, params[:role])
      scope = by_plan(scope, params[:plan])
      scope = by_active(scope, params[:active])

      apply_order(scope, params[:order]).preload(:roles)
    end

    private

    def by_search(scope, term)
      pattern = "%#{User.sanitize_sql_like(term.to_s.strip)}%"

      scope.where(
        'users.email ILIKE :pattern OR users.first_name ILIKE :pattern OR users.last_name ILIKE :pattern',
        pattern: pattern
      )
    end

    def by_role(scope, role)
      normalized = role.to_s
      return scope unless ROLES.include?(normalized)
      return scope.where.not(id: User.joins(:roles).select(:id)) if normalized == 'none'

      scope.where(id: User.with_role(normalized.to_sym).select(:id))
    end

    def by_active(scope, active)
      confirmed = ActiveModel::Type::Boolean.new.cast(active)
      return scope if confirmed.nil?

      confirmed ? scope.where.not(confirmed_at: nil) : scope.where(confirmed_at: nil)
    end

    def by_plan(scope, plan)
      return scope unless User::PLANS.include?(plan.to_s)

      scope.where(plan: plan.to_s).where.not(id: User.with_role(:admin).select(:id))
    end

    def apply_order(scope, value)
      scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
    end
  end
end
