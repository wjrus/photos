class ApplicationMailer < ActionMailer::Base
  default from: -> { MailgunClient.default_from }
  layout "mailer"
end
