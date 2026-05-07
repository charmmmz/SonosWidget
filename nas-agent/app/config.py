from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    agent_port: int = 8790
    openai_api_key: str = ""
    openai_model: str = "gpt-4o-mini"
    node_base_url: str = "http://127.0.0.1:8787"
    internal_api_token: str = ""
    agent_user_token: str = ""
    database_path: str = "/app/data/agent.db"
    habit_poll_seconds: int = 60


settings = Settings()
