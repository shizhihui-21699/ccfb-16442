# frozen_string_literal: true

# ISMS 持续监测引擎 —— 零外部依赖的核心库入口
require_relative "isms/support/time_range"
require_relative "isms/canonical/models"
require_relative "isms/domain/identity_mapper"
require_relative "isms/domain/exception_window"
require_relative "isms/connectors/base"
require_relative "isms/connectors/hr_connector"
require_relative "isms/connectors/cloud_connector"
require_relative "isms/connectors/repo_connector"
require_relative "isms/connectors/patch_connector"
require_relative "isms/connectors/ticket_connector"
require_relative "isms/engine/rule_loader"
require_relative "isms/engine/control_result"
require_relative "isms/engine/evaluator"
require_relative "isms/evidence/packager"

module ISMS
  VERSION = "0.1.0"
end
