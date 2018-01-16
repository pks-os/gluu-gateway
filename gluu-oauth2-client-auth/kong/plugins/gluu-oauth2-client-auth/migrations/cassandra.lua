return {
    {
        name = "2018-01-15541_init_gluu_oauth2_client_auth_credentials",
        up = [[
      CREATE TABLE IF NOT EXISTS gluu_oauth2_client_auth_credentials(
        id uuid,
        consumer_id uuid,
        redirect_uris text,
        scope text,
        grant_types text,
        client_name text,
        op_host text,
        client_id text,
        client_secret text,
        token_endpoint text,
        introspection_endpoint text,
        jwks_uri text,
        jwks_file text,
        token_endpoint_auth_method text,
        token_endpoint_auth_signing_alg text,
        created_at timestamp,
        PRIMARY KEY (id)
      );
      CREATE INDEX IF NOT EXISTS ON gluu_oauth2_client_auth_credentials(consumer_id);
      CREATE INDEX IF NOT EXISTS ON gluu_oauth2_client_auth_credentials(client_id);
      CREATE INDEX IF NOT EXISTS ON gluu_oauth2_client_auth_credentials(client_secret);
    ]],
        down = [[
      DROP TABLE gluu_oauth2_client_auth_credential;
    ]]
    }
}