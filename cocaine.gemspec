# -*- encoding: utf-8 -*-
require File.expand_path('../lib/cocaine/version', __FILE__)

Gem::Specification.new do |s|
  s.name = 'cocaine-framework'
  s.version = Cocaine::VERSION
  s.homepage = 'https://github.com/cocaine/cocaine-framework-ruby'
  s.licenses = %w(Ruby LGPLv3)

  s.authors = ['Evgeny Safronov']
  s.email   = ['division494@gmail.com']

  s.files = %w(lib/cocaine.rb lib/cocaine/cocaine.rb lib/cocaine/version.rb)
  s.extensions = []

  s.summary = 'Ruby/Cocaine library'
  s.description = 'Cocaine Framework is a framework for simplifying development both server-side and client-side
applications.'

  s.required_ruby_version = '>= 1.9'

  s.add_runtime_dependency 'msgpack', '~> 1.0'
  s.add_runtime_dependency 'celluloid', '~> 0.16'
  s.add_runtime_dependency 'celluloid-io', '~> 0.16'

  s.add_development_dependency 'rspec', '~> 3.2'
  s.add_development_dependency 'rake', '~> 10.0'
  s.add_development_dependency 'bundler', '~> 1.7'
end
