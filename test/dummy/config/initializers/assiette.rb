# frozen_string_literal: true

ActiveSupport.on_load(:action_controller_base) do
  helper Assiette::Helpers
end
