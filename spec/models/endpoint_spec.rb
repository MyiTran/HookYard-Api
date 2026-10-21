require 'rails_helper'

describe Endpoint, type: :model do
  describe 'validations' do
    context 'when the name is missing' do
      it 'is invalid' do
        endpoint = build(:endpoint, name: nil)

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:name]).to be_present
      end
    end

    context 'when the url is missing' do
      it 'is invalid' do
        endpoint = build(:endpoint, url: nil)

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:url]).to be_present
      end
    end

    context 'when the url is not a valid HTTP(S) URL' do
      it 'is invalid' do
        endpoint = build(:endpoint, url: 'ftp://example.com/hooks')

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:url]).to be_present
      end

      it 'rejects a malformed url' do
        endpoint = build(:endpoint, url: 'not a url')

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:url]).to be_present
      end
    end

    context 'when the url is a valid HTTP(S) URL' do
      it 'is valid' do
        expect(build(:endpoint, url: 'http://example.com/hooks')).to be_valid
        expect(build(:endpoint, url: 'https://example.com/hooks')).to be_valid
      end

      it 'accepts a public destination with a custom port' do
        expect(build(:endpoint, url: 'https://example.com:8443/hooks')).to be_valid
        expect(build(:endpoint, url: 'http://example.com:8080/hooks')).to be_valid
      end

      it 'accepts public IP literals' do
        expect(build(:endpoint, url: 'http://93.184.216.34/hooks')).to be_valid
        expect(build(:endpoint, url: 'https://[2606:4700:4700::1111]/hooks')).to be_valid
      end
    end

    context 'when the url points to a loopback destination' do
      it 'is invalid' do
        expect_invalid_url('http://127.0.0.1/hooks')
        expect_invalid_url('http://localhost/hooks')
        expect_invalid_url('http://LOCALHOST./hooks')
        expect_invalid_url('http://[::1]/hooks')
        expect_invalid_url('http://[::ffff:127.0.0.1]/hooks')
      end
    end

    context 'when the url points to a private network' do
      it 'is invalid' do
        expect_invalid_url('http://10.1.2.3/hooks')
        expect_invalid_url('http://172.16.5.4/hooks')
        expect_invalid_url('http://192.168.1.10/hooks')
        expect_invalid_url('http://[fd00::1]/hooks')
      end
    end

    context 'when the url points to a reserved destination' do
      it 'is invalid' do
        expect_invalid_url('http://169.254.169.254/latest/meta-data')
        expect_invalid_url('http://[fe80::1]/hooks')
        expect_invalid_url('http://0.0.0.0/hooks')
        expect_invalid_url('http://[::]/hooks')
        expect_invalid_url('http://224.0.0.1/hooks')
        expect_invalid_url('http://100.64.1.1/hooks')
        expect_invalid_url('http://192.0.2.10/hooks')
        expect_invalid_url('http://198.18.0.1/hooks')
        expect_invalid_url('http://203.0.113.10/hooks')
        expect_invalid_url('http://240.0.0.1/hooks')
      end
    end

    context 'when the url uses an ambiguous numeric host' do
      it 'is invalid' do
        expect_invalid_url('http://2130706433/hooks')
        expect_invalid_url('http://0x7f000001/hooks')
        expect_invalid_url('http://0x7f.0.0.1/hooks')
        expect_invalid_url('http://127.1/hooks')
        expect_invalid_url('http://0177.0.0.1/hooks')
      end
    end

    context 'when the url targets an internal hostname' do
      it 'is invalid' do
        expect_invalid_url('http://intranet/hooks')
        expect_invalid_url('http://billing.local/hooks')
        expect_invalid_url('http://api.internal/hooks')
        expect_invalid_url('http://service.lan/hooks')
      end
    end

    context 'when the url embeds credentials' do
      it 'is invalid' do
        expect_invalid_url('http://user:password@example.com/hooks')
      end
    end

    context 'when event_types contains a blank value' do
      it 'is invalid' do
        endpoint = build(:endpoint, event_types: ['order.created', ''])

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:event_types]).to be_present
      end
    end

    context 'when event_types contains duplicates' do
      it 'is invalid' do
        endpoint = build(:endpoint, event_types: %w[order.created order.created])

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:event_types]).to be_present
      end
    end

    context "when event_types combines '*' with specific event types" do
      it 'is invalid' do
        endpoint = build(:endpoint, event_types: ['*', 'order.created'])

        expect(endpoint).not_to be_valid
        expect(endpoint.errors[:event_types]).to be_present
      end
    end

    context "when event_types uses only '*'" do
      it 'is valid' do
        expect(build(:endpoint, event_types: ['*'])).to be_valid
      end
    end

    context 'when event_types lists multiple specific event types' do
      it 'is valid' do
        expect(build(:endpoint, event_types: %w[order.created order.updated])).to be_valid
      end
    end

    def expect_invalid_url(url)
      endpoint = build(:endpoint, url: url)

      expect(endpoint).not_to be_valid, "expected #{url} to be rejected"
      expect(endpoint.errors[:url]).to be_present
    end
  end

  describe '#archived?' do
    context 'when archived_at is present' do
      it 'is archived' do
        expect(build(:endpoint, archived_at: Time.current)).to be_archived
      end
    end

    context 'when archived_at is nil' do
      it 'is not archived' do
        expect(build(:endpoint, archived_at: nil)).not_to be_archived
      end
    end
  end

  describe '#subscribed_to?' do
    context "when subscribed to '*'" do
      let(:endpoint) { build(:endpoint, event_types: ['*']) }

      it 'matches any event type' do
        expect(endpoint.subscribed_to?('order.created')).to be(true)
        expect(endpoint.subscribed_to?('user.deleted')).to be(true)
      end
    end

    context 'when subscribed to specific event types' do
      let(:endpoint) { build(:endpoint, event_types: %w[order.created order.updated]) }

      it 'matches only the listed event types' do
        expect(endpoint.subscribed_to?('order.created')).to be(true)
        expect(endpoint.subscribed_to?('user.deleted')).to be(false)
      end
    end
  end

  describe '#rotate_signing_secret!' do
    let(:endpoint) { create(:endpoint) }

    it 'generates a raw secret and stores it encrypted' do
      secret = endpoint.rotate_signing_secret!

      expect(secret.secret).to be_present
      expect(secret.version).to eq(2)
      expect(secret.ciphertext_for(:secret)).not_to include(secret.secret)
    end

    it 'immediately switches the current secret to the new version' do
      previous = endpoint.current_signing_secret

      rotated = endpoint.rotate_signing_secret!

      expect(previous.reload).to be_retired
      expect(rotated).not_to be_retired
      expect(endpoint.current_signing_secret).to eq(rotated)
      expect(rotated.version).to eq(previous.version + 1)
    end

    it 'retires every previous version and keeps exactly one current version' do
      endpoint.rotate_signing_secret!
      endpoint.rotate_signing_secret!

      expect(endpoint.endpoint_signing_secrets.current.pluck(:version)).to eq([3])
      expect(endpoint.endpoint_signing_secrets.where.not(retired_at: nil).pluck(:version)).to eq([1, 2])
      expect(endpoint.current_signing_secret.version).to eq(3)
    end

    it 'keeps retired versions persisted as historical data only' do
      previous = endpoint.current_signing_secret
      rotated = endpoint.rotate_signing_secret!

      expect(endpoint.endpoint_signing_secrets.pluck(:id)).to contain_exactly(previous.id, rotated.id)
      expect(previous.reload.secret).to be_present
      expect(rotated.secret).not_to eq(previous.secret)
    end

    it 'never returns a retired version from #current_signing_secret' do
      first = endpoint.current_signing_secret
      endpoint.rotate_signing_secret!
      second = endpoint.current_signing_secret
      endpoint.rotate_signing_secret!

      current = endpoint.current_signing_secret

      expect(current).not_to be_retired
      expect(current).not_to eq(first)
      expect(current).not_to eq(second)
    end

    it 'leaves the previous current secret intact when rotation fails' do
      previous = endpoint.current_signing_secret
      allow(endpoint).to receive(:new_signing_secret).and_raise(ActiveRecord::RecordNotUnique)

      expect { endpoint.rotate_signing_secret! }.to raise_error(ActiveRecord::RecordNotUnique)

      expect(endpoint.reload.current_signing_secret).to eq(previous)
      expect(previous.reload).not_to be_retired
      expect(endpoint.endpoint_signing_secrets.count).to eq(1)
    end

    it 'enforces a single current secret at the database level' do
      current = endpoint.current_signing_secret

      expect { endpoint.endpoint_signing_secrets.create!(version: 2, secret: 'another') }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect(endpoint.endpoint_signing_secrets.current).to contain_exactly(current)
    end

    context 'when rotations run concurrently' do
      self.use_transactional_tests = false

      after { endpoint.project.destroy! }

      it 'keeps a single current secret with continuous versions' do
        endpoint_id = endpoint.id
        start = Queue.new

        threads = Array.new(3) do
          Thread.new do
            start.pop
            ActiveRecord::Base.connection_pool.with_connection do
              described_class.find(endpoint_id).rotate_signing_secret!
            end
          end
        end

        3.times { start.push(true) }
        threads.each(&:join)

        endpoint.reload
        expect(endpoint.current_signing_secret.version).to eq(4)
        expect(endpoint.endpoint_signing_secrets.current.count).to eq(1)
        expect(endpoint.endpoint_signing_secrets.order(:version).pluck(:version)).to eq([1, 2, 3, 4])
      end
    end
  end

  describe '#has_signing_secret?' do
    it 'is true once a secret exists' do
      expect(create(:endpoint)).to have_signing_secret
    end

    it 'is false before any secret is generated' do
      expect(build(:endpoint)).not_to have_signing_secret
    end
  end

  describe '#signing_secret_version' do
    it 'returns the current version' do
      endpoint = create(:endpoint)
      endpoint.rotate_signing_secret!

      expect(endpoint.signing_secret_version).to eq(2)
    end
  end
end
