class UserDashboardSerializer < ApplicationSerializer
  field(:workspace) { |dashboard| dashboard[:workspace] }

  field(:delivery_health) { |dashboard| dashboard[:delivery_health] }

  field(:needs_attention) { |dashboard| dashboard[:needs_attention] }

  field(:projects) { |dashboard| dashboard[:projects] }
end
