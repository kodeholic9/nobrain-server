module.exports = {
  apps : [{
    name: 'my-rest-api', // PM2에서 앱을 식별하는 이름
    script: 'app.js',
    instances: 1, // 라즈베리 파이에서는 보통 1
    autorestart: true,
    watch: false, // 운영 환경에서는 watch 끄기
    max_memory_restart: '1G', // 라즈베리 파이 램 용량에 따라 적절히 조절 (예: 512M)
    env: {
      NODE_ENV: 'development',
      // YOUTUBE_DATA_API_KEY: process.env.YOUTUBE_DATA_API_KEY, // 이 방식 대신 .env 파일을 시스템 환경변수로 로드하는 것이 권장
    },
    env_production: {
      NODE_ENV: 'production',
      PORT: 1793, // 운영 포트 명시
    },
    // --- 이 부분이 중요합니다 ---
    // 앱을 www-data 사용자로 실행하도록 설정
    user: 'www-data',
    group: 'www-data',
  }],
};