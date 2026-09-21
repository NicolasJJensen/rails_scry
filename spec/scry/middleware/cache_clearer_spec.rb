require 'rails_helper'
require 'active_job'

RSpec.describe Scry::Middleware::CacheClearer do
  let(:response) { [200, {}, ['OK']] }
  let(:app) { ->(env) { response } }
  let(:middleware) { described_class.new(app) }

  after(:each) do
    Thread.current[:scry_caches] = nil
    Thread.current[:scry_cache_versions] = nil
  end

  describe '#call' do
    it 'delegates to the app and returns its response' do
      result = middleware.call({})
      expect(result).to eq(response)
    end

    it 'clears thread-local caches after each request' do
      Thread.current[:scry_caches] = { some_key: 'cached_value' }
      Thread.current[:scry_cache_versions] = { model: 1 }

      middleware.call({})

      expect(Thread.current[:scry_caches]).to be_empty
      expect(Thread.current[:scry_cache_versions]).to be_empty
    end

    it 'clears caches even when the app raises an exception' do
      Thread.current[:scry_caches] = { data: true }
      Thread.current[:scry_cache_versions] = { model: 1 }

      error_app = ->(_env) { raise RuntimeError, 'boom' }
      error_middleware = described_class.new(error_app)

      expect { error_middleware.call({}) }.to raise_error(RuntimeError, 'boom')

      expect(Thread.current[:scry_caches]).to be_empty
      expect(Thread.current[:scry_cache_versions]).to be_empty
    end

    it 'is safe when no caches exist' do
      Thread.current[:scry_caches] = nil
      Thread.current[:scry_cache_versions] = nil

      expect { middleware.call({}) }.not_to raise_error
    end
  end

  describe '.clear_current_thread!' do
    it 'clears both thread-local keys' do
      Thread.current[:scry_caches] = { key: 'value' }
      Thread.current[:scry_cache_versions] = { first_model: 1, second_model: 2 }

      described_class.clear_current_thread!

      expect(Thread.current[:scry_caches]).to be_empty
      expect(Thread.current[:scry_cache_versions]).to be_empty
    end

    it 'is safe when no caches exist' do
      Thread.current[:scry_caches] = nil
      Thread.current[:scry_cache_versions] = nil

      expect { described_class.clear_current_thread! }.not_to raise_error
    end
  end

  describe 'the documented ActiveJob callback' do
    it 'clears both caches when a job raises before the thread is reused' do
      job_class = Class.new(ActiveJob::Base) do
        around_perform do |_job, block|
          block.call
        ensure
          Scry::Middleware::CacheClearer.clear_current_thread!
        end

        define_method(:perform) do |raise_error:|
          Thread.current[:scry_caches] = { permission: 'cached' }
          Thread.current[:scry_cache_versions] = { User: 1 }
          raise 'job failed' if raise_error
        end
      end

      thread = Thread.new do
        Thread.current[:scry_caches] = {}
        Thread.current[:scry_cache_versions] = {}

        expect { job_class.perform_now(raise_error: true) }.to raise_error('job failed')

        expect(Thread.current[:scry_caches]).to be_empty
        expect(Thread.current[:scry_cache_versions]).to be_empty

        job_class.perform_now(raise_error: false)
      end

      thread.value
    end
  end
end
