if Rails.env.production?
  Rails.application.config.public_file_server.enabled = true

  if ENV["FORCE_SSL"] == "false"
    Rails.application.config.force_ssl = false
  end
end
