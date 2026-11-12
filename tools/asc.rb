#!/usr/bin/ruby
# Tiny App Store Connect API client using the shared key in ~/.appstoreconnect (see tools/phone.sh).
#
#     tools/asc.rb GET  /v1/apps?filter[bundleId]=com.kezlahd.jot
#     tools/asc.rb POST /v1/bundleIds '{"data":{...}}'
require "openssl"
require "json"
require "base64"
require "net/http"

env = File.read(File.expand_path("~/.appstoreconnect/asc.env")).scan(/^(\w+)=(.*)$/).to_h
kid, iss = env.fetch("ASC_KEY_ID"), env.fetch("ASC_ISSUER_ID")
key = OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{kid}.p8")))

b64 = ->(s) { Base64.urlsafe_encode64(s, padding: false) }
header = b64.(JSON.dump(alg: "ES256", kid: kid, typ: "JWT"))
payload = b64.(JSON.dump(iss: iss, iat: Time.now.to_i, exp: Time.now.to_i + 600, aud: "appstoreconnect-v1"))
der = key.sign(OpenSSL::Digest::SHA256.new, "#{header}.#{payload}")
r, s = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\0")[-32..] }
token = "#{header}.#{payload}.#{b64.(r + s)}"

method, path, body = ARGV
uri = URI("https://api.appstoreconnect.apple.com#{path}")
req = Net::HTTP.const_get(method.capitalize).new(uri)
req["Authorization"] = "Bearer #{token}"
req["Content-Type"] = "application/json"
req.body = body if body
res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
warn "HTTP #{res.code}"
puts res.body
