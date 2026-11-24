# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "isms"

class ExceptionWindowTest < Minitest::Test
  def valid_attrs
    { exception_id: "EX-1", control_id: "ACC-01", resource_ref: "account:x",
      start_time: "2026-08-01T00:00:00Z", end_time: "2026-08-10T00:00:00Z",
      status: "approved", requested_by: "u1", approved_by: "m1",
      reason: "交接保留", compensating_controls: ["只读权限"] }
  end

  def test_valid_exception
    ex = ISMS::Domain::ExceptionWindow.new(valid_attrs)
    assert ex.valid?
    assert ex.active_at?(Time.parse("2026-08-05T00:00:00Z"))
    refute ex.active_at?(Time.parse("2026-08-10T00:00:00Z")) # 半开区间
  end

  def test_self_approval_violates_segregation_of_duties
    ex = ISMS::Domain::ExceptionWindow.new(valid_attrs.merge(approved_by: "u1"))
    refute ex.valid?
    assert_match(/职责分离/, ex.validation_errors.join)
  end

  def test_unapproved_exception_is_invalid
    ex = ISMS::Domain::ExceptionWindow.new(valid_attrs.merge(status: "pending"))
    refute ex.valid?
  end

  def test_expired_exception_does_not_apply
    ex = ISMS::Domain::ExceptionWindow.new(valid_attrs)
    refute ex.active_at?(Time.parse("2026-09-01T00:00:00Z"))
  end

  def test_scope_mismatch_means_not_applicable
    ex = ISMS::Domain::ExceptionWindow.new(valid_attrs)
    refute ex.applies_to?(control_id: "PM-01", resource_ref: "account:x")
    refute ex.applies_to?(control_id: "ACC-01", resource_ref: "account:y")
  end
end
