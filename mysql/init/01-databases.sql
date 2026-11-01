-- Runs once, when the MySQL volume is created.
-- One database per service. The application user gets access to all of them (local only).
CREATE DATABASE IF NOT EXISTS wallet_core CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS rates_service CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS treasury_service CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

GRANT ALL PRIVILEGES ON wallet_core.* TO 'wallet'@'%';
GRANT ALL PRIVILEGES ON rates_service.* TO 'wallet'@'%';
GRANT ALL PRIVILEGES ON treasury_service.* TO 'wallet'@'%';
FLUSH PRIVILEGES;
