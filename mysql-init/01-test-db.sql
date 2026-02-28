-- Create arcana_test database for CI/CD integration tests
CREATE DATABASE IF NOT EXISTS arcana_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON arcana_test.* TO 'jrjohn'@'%';
FLUSH PRIVILEGES;
