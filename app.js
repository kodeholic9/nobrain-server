const express = require('express');
const path = require('path');
const fs = require('fs');
const winston = require('winston'); // winston 모듈 추가

// dotenv를 사용하여 .env 파일에서 환경 변수 로드 (개발/로컬에서 유용)
// 운영 환경에서는 시스템 환경 변수를 직접 설정합니다.
require('dotenv').config();

// --- 보안 경고: YOUTUBE_DATA_API_KEY는 클라이언트에 직접 노출하면 안 됩니다! ---
const YOUTUBE_DATA_API_KEY = process.env.YOUTUBE_DATA_API_KEY;
// console.log(`Application YOUTUBE_DATA_API_KEY: `, YOUTUBE_DATA_API_KEY); // 운영 환경에서는 이 로그도 주의

// 현재 환경 확인
const ENV = process.env.NODE_ENV || 'development';
console.log(`Application running in ${ENV} environment.`); // 초기 콘솔 로그

// config 파일 로드
const configFileName = `app.${ENV}.json`;
const configPath = path.join(__dirname, 'config', configFileName);
let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  console.log(`Configuration loaded from: ${configFileName}`); // 초기 콘솔 로그
} catch (err) {
  console.error(`Error loading config file ${configFileName}:`, err.message); // 에러 메시지 수정
  process.exit(1);
}

// Winston 로거 설정
// config.logPath가 정의되었는지 확인하고, 없으면 기본값 설정
const logFilePath =
  config.logPath || path.join(__dirname, 'logs', `${ENV}.log`);

const logger = winston.createLogger({
  level: ENV === 'production' ? 'info' : 'debug',
  format: winston.format.combine(
    winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }), // 타임스탬프 형식 지정
    winston.format.printf(
      (info) =>
        `${info.timestamp} [${info.level.toUpperCase()}]: ${info.message}`
    )
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: logFilePath }),
  ],
});

const app = express();
const PORT = process.env.PORT || config.port || 3000;

app.use(express.json());

// 모든 요청에 대한 로그 (Morgan 대신 간단 구현)
app.use((req, res, next) => {
  logger.info(`Request: ${req.method} ${req.originalUrl} from ${req.ip}`);
  next();
});

// 특정 API 경로에 대한 응답 (예: /api/v1/users)
app.get(`/api/${config.api_version}/:resource`, (req, res) => {
  const resource = req.params.resource;

  logger.debug(`API request received for resource: ${resource}`);

  switch (resource) {
    case 'y-data-api-key':
      // 🚨🚨🚨 보안 경고: 클라이언트에 API 키를 직접 노출하지 마세요! 🚨🚨🚨
      logger.warn(
        `Attempted to expose YOUTUBE_DATA_API_KEY via API. This is not recommended.`
      );
      return res
        .status(403)
        .json({ error: 'API key exposure is not allowed.' }); // 403 Forbidden 응답 권장

    default:
      const filePath = path.join(config.dataRoot, '', `${resource}.json`); // config.dataPath 사용
      logger.debug(`Attempting to read file from: ${filePath}`);

      fs.readFile(filePath, 'utf8', (err, data) => {
        if (err) {
          if (err.code === 'ENOENT') {
            logger.warn(`Resource file not found: ${filePath}`);
            return res
              .status(404)
              .json({ error: `Resource '${resource}' not found.` });
          }
          logger.error(`Error reading file ${filePath}:`, err.message);
          return res.status(500).json({ error: 'Internal server error.' });
        }
        try {
          const jsonData = JSON.parse(data);
          logger.debug(`Successfully parsed JSON data from ${filePath}`);
          res.json(jsonData);
        } catch (parseErr) {
          logger.error(
            `Error parsing JSON from ${filePath}:`,
            parseErr.message
          );
          res.status(500).json({ error: 'Invalid data format.' });
        }
      });
      break;
  }
});

// 루트 경로 응답 (옵션)
app.get('/', (req, res) => {
  logger.debug('Root path requested.');
  res.send(
    `Welcome to the Node.js REST API server (v${config.api_version})! Running in ${ENV} mode.`
  );
});

app.listen(PORT, () => {
  logger.info(`Server is running on port ${PORT}`);
  logger.info(`API Version: ${config.api_version}`);
  logger.info(`Environment: ${config.environment}`);
  logger.info(`Logs are being written to: ${logFilePath}`);
});

// 프로세스 예외/비정상 종료 시 로깅
process.on('uncaughtException', (err) => {
  logger.error(`Uncaught Exception: ${err.message}`, err);
  // 운영 환경에서는 PM2가 재시작하므로, 강제 종료를 하지 않을 수도 있습니다.
  // 하지만 즉시 종료하여 상태가 꼬이는 것을 방지하는 것이 더 안전할 수 있습니다.
  // process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  logger.error(
    `Unhandled Rejection at Promise: ${promise}, reason: ${reason}`,
    reason
  );
});
