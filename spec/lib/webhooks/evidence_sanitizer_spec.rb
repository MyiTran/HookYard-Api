require 'rails_helper'

describe Webhooks::EvidenceSanitizer do
  describe '.sanitize_headers' do
    it 'drops credential headers and internal timing headers' do
      headers = {
        'Authorization' => 'Bearer secret',
        'cookie' => 'session=1',
        'set-cookie' => ['session=1'],
        'webhook-signature' => 'v1,abc',
        'x-api-key' => 'key',
        'Server-Timing' => 'sql;dur=12',
        'content-type' => 'application/json',
        'x-trace' => 'trace-1'
      }

      expect(described_class.sanitize_headers(headers)).to eq(
        'content-type' => 'application/json',
        'x-trace' => 'trace-1'
      )
    end

    it 'keeps missing headers missing' do
      expect(described_class.sanitize_headers(nil)).to be_nil
    end
  end

  describe '.sanitize_url' do
    it 'redacts sensitive query parameter values and keeps the safe ones' do
      url = 'https://example.test/hooks?token=abc&page=2&api_key=k&signature=s'

      expect(described_class.sanitize_url(url)).to eq(
        'https://example.test/hooks?token=[REDACTED]&page=2&api_key=[REDACTED]&signature=[REDACTED]'
      )
    end

    it 'keeps legitimate endpoint parameters untouched' do
      url = 'https://example.test/hooks/orders?tenant=acme&page=3#section'

      expect(described_class.sanitize_url(url)).to eq(url)
    end

    it 'returns urls without a query unchanged' do
      url = 'https://example.test/hooks'

      expect(described_class.sanitize_url(url)).to eq(url)
    end
  end

  describe '.sanitize_body' do
    it 'redacts sensitive keys in nested objects and arrays' do
      body = {
        'event' => 'order.created',
        'token' => 'tok_live',
        'data' => {
          'password' => 'hunter2',
          'api_key' => 'key-1',
          'authorization' => 'Bearer abc',
          'items' => [{ 'token' => 'inner', 'name' => 'widget' }]
        }
      }.to_json

      sanitized = described_class.sanitize_body(body)

      expect(JSON.parse(sanitized)).to eq(
        'event' => 'order.created',
        'token' => '[REDACTED]',
        'data' => {
          'password' => '[REDACTED]',
          'api_key' => '[REDACTED]',
          'authorization' => '[REDACTED]',
          'items' => [{ 'token' => '[REDACTED]', 'name' => 'widget' }]
        }
      )
    end

    it 'keeps safe keys and the json structure untouched' do
      body = { 'items' => [{ 'name' => 'a' }, { 'secret' => 's' }], 'count' => 2 }.to_json

      sanitized = described_class.sanitize_body(body)

      expect(JSON.parse(sanitized)).to eq('items' => [{ 'name' => 'a' }, { 'secret' => '[REDACTED]' }], 'count' => 2)
    end

    it 'redacts sensitive keys regardless of their case' do
      body = { 'Authorization' => 'a', 'PASSWORD' => 'p', 'Api_Key' => 'k', 'Token' => 't', 'order' => 'o' }.to_json

      expect(JSON.parse(described_class.sanitize_body(body))).to eq(
        'Authorization' => '[REDACTED]',
        'PASSWORD' => '[REDACTED]',
        'Api_Key' => '[REDACTED]',
        'Token' => '[REDACTED]',
        'order' => 'o'
      )
    end

    it 'redacts credential keys in nested objects and arrays' do
      body = {
        'client' => {
          'refresh_token' => 'refresh-1',
          'client_secret' => 'secret-1',
          'private_key' => 'pk-1',
          'access_key' => 'ak-1',
          'card' => { 'card-number' => '4111111111111111', 'cvv' => '123' }
        },
        'sessions' => [
          { 'session_token' => 'session-1', 'id_token' => 'id-1', 'cvc' => '456' },
          { 'name' => 'safe-entry' }
        ]
      }.to_json

      sanitized = described_class.sanitize_body(body)

      expect(JSON.parse(sanitized)).to eq(
        'client' => {
          'refresh_token' => '[REDACTED]',
          'client_secret' => '[REDACTED]',
          'private_key' => '[REDACTED]',
          'access_key' => '[REDACTED]',
          'card' => { 'card-number' => '[REDACTED]', 'cvv' => '[REDACTED]' }
        },
        'sessions' => [
          { 'session_token' => '[REDACTED]', 'id_token' => '[REDACTED]', 'cvc' => '[REDACTED]' },
          { 'name' => 'safe-entry' }
        ]
      )
    end

    it 'redacts the extended credential keys regardless of their case' do
      body = {
        'Refresh_Token' => 'r',
        'CLIENT-SECRET' => 'c',
        'Private_Key' => 'p',
        'ACCESS-KEY' => 'a',
        'Session-Token' => 's',
        'ID_TOKEN' => 'i',
        'Card-Number' => '4111111111111111',
        'CVV' => '123',
        'Cvc' => '456',
        'order_id' => 'order-1',
        'shipping' => { 'city' => 'Ha Noi' }
      }.to_json

      expect(JSON.parse(described_class.sanitize_body(body))).to eq(
        'Refresh_Token' => '[REDACTED]',
        'CLIENT-SECRET' => '[REDACTED]',
        'Private_Key' => '[REDACTED]',
        'ACCESS-KEY' => '[REDACTED]',
        'Session-Token' => '[REDACTED]',
        'ID_TOKEN' => '[REDACTED]',
        'Card-Number' => '[REDACTED]',
        'CVV' => '[REDACTED]',
        'Cvc' => '[REDACTED]',
        'order_id' => 'order-1',
        'shipping' => { 'city' => 'Ha Noi' }
      )
    end

    it 'keeps a body that is not json unchanged' do
      expect(described_class.sanitize_body('internal server error')).to eq('internal server error')
    end

    it 'keeps a missing body missing' do
      expect(described_class.sanitize_body(nil)).to be_nil
    end
  end
end
