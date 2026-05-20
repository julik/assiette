# frozen_string_literal: true

require "digest/sha1"

module Assiette
  # Computes a short version tag for cache busting.
  # In development: timestamp for instant invalidation on each request
  # In production: derived from APP_REVISION env var or Gemfile.lock digest
  def self.version_tag
    @version_tag ||= compute_version_tag
  end

  def self.reset_version_tag!
    @version_tag = nil
  end

  def self.compute_version_tag
    if Rails.env.development?
      Time.now.utc.strftime("%Y%m%d%H%M%S")
    elsif (app_revision = ENV["APP_REVISION"]).present?
      Digest::SHA1.hexdigest(app_revision)[0, 4]
    else
      gemfile_lock_path = Rails.root.join("Gemfile.lock")
      if gemfile_lock_path.exist?
        Digest::SHA1.file(gemfile_lock_path).hexdigest[0, 4]
      else
        (Time.now.utc.to_i / 300).to_s(16)
      end
    end
  end

  private_class_method :compute_version_tag
end
