#!/bin/bash

# --- 설정 변수 ---
BACKUP_BASE_DIR="$HOME/nobrain-server/backup"   # 백업 파일을 저장할 기본 디렉토리
BUILD_DIR="$HOME/nobrain-server/src"         # Git 클론 및 빌드를 수행할 임시 디렉토리

# 실제 웹 서버 애플리케이션이 배포될 디렉토리 (심볼릭 링크 대상)
# 이 디렉토리는 www-data:www-data 소유권이어야 합니다.
WEB_APP_DEST_BASE_DIR="/var/www" # 실제 앱 코드가 위치할 디렉토리의 상위 디렉토리 (예: /var/www/nobrain-server_v20250622)

# 심볼릭 링크 이름
WEB_APP_LINK_NAME="/var/www/api-server" # Nginx가 실제 바라볼 심볼릭 링크 이름 (기존 디렉토리 이름 활용)

GIT_REPO_URL="https://github.com/kodeholic9/nobrain-server.git"
GIT_BRANCH="r1.0.0"

# PM2 앱 이름 (ecosystem.config.js와 일치해야 함)
PM2_APP_NAME="nobrain-server"

# Node.js 실행에 필요한 환경 변수 (운영용)
NODE_ENV_PROD="production"

# --- 스크립트 시작 ---
echo "========================================"
echo " Node.js API 서버 배포 스크립트 시작"
echo "========================================"

# 첫 번째 인자로 명령을 받음 (start, stop, restart, patch)
COMMAND=$1

if [ -z "$COMMAND" ]; then
    echo "사용법: $0 [start|stop|restart|patch]"
    exit 1
fi

# --- 함수 정의 ---

# 백업 함수
backup_current_app() {
    echo "--- 1. 기존 앱 백업 시작 ---"
    mkdir -p "$BACKUP_BASE_DIR" # 백업 디렉토리 생성
    CURRENT_DATETIME=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILENAME="${PM2_APP_NAME}_${CURRENT_DATETIME}.tar.gz"
    BACKUP_FULL_PATH="${BACKUP_BASE_DIR}/${BACKUP_FILENAME}"

    if [ -L "$WEB_APP_LINK_NAME" ] && [ -d "$(readlink -f "$WEB_APP_LINK_NAME")" ]; then # 심볼릭 링크가 존재하고 유효한 경우
        local CURRENT_APP_DIR="$(readlink -f "$WEB_APP_LINK_NAME")" # 현재 심볼릭 링크가 가리키는 실제 디렉토리
        echo "현재 웹 앱 디렉토리 백업 중: ${CURRENT_APP_DIR} -> ${BACKUP_FULL_PATH}"
        sudo tar -czf "$BACKUP_FULL_PATH" -C "$(dirname "$CURRENT_APP_DIR")" "$(basename "$CURRENT_APP_DIR")"
        if [ $? -eq 0 ]; then
            echo "백업 성공: ${BACKUP_FULL_PATH}"
        else
            echo "오류: 백업에 실패했습니다. (권한 또는 디스크 공간 문제일 수 있습니다)"
            return 1 # 함수 실패 시 반환
        fi
    else
        echo "경고: 현재 활성화된 웹 앱 디렉토리 (${WEB_APP_LINK_NAME})가 존재하지 않거나 유효하지 않아 백업을 건너킵니다."
    fi
    echo "--- 1. 기존 앱 백업 완료 ---"
    return 0
}

# Git 클론 및 빌드 함수
clone_and_build() {
    echo "--- 2. Git 클론 및 빌드 시작 ---"
    echo "기존 빌드 디렉토리 삭제: ${BUILD_DIR}"
    # Git 클론 전에 상위 디렉토리 생성 및 기존 디렉토리 정리
    mkdir -p "$(dirname "$BUILD_DIR")" # ~/nobrain-server 생성
    sudo rm -rf "$BUILD_DIR" # 임시 빌드 디렉토리 삭제 (sudo 필요)

    echo "Git 리포지토리 클론 중: ${GIT_REPO_URL} (${GIT_BRANCH} 브랜치) -> ${BUILD_DIR}"
    git clone --single-branch --branch "$GIT_BRANCH" "$GIT_REPO_URL" "$BUILD_DIR"
    if [ $? -eq 0 ]; then
        echo "Git 클론 성공."
    else
        echo "오류: Git 클론에 실패했습니다."
        return 1
    fi

    echo "빌드 디렉토리 소유권 www-data:www-data로 변경: ${BUILD_DIR}"
    sudo chown -R www-data:www-data "$BUILD_DIR"

    echo "Node.js 의존성 설치 (npm install) 시작: ${BUILD_DIR}"
    cd "$BUILD_DIR" || { echo "오류: ${BUILD_DIR}로 이동할 수 없습니다."; return 1; }

    # npm install 시 node_modules를 www-data가 소유하도록 sudo -u www-data 로 실행
    sudo -u www-data npm install
    if [ $? -eq 0 ]; then
        echo "npm install 성공."
    else
        echo "오류: npm install에 실패했습니다."
        return 1
    fi
    echo "--- 2. Git 클론 및 빌드 완료 ---"
    return 0
}

# 새 버전 배포 및 심볼릭 링크 전환 함수
deploy_new_version() {
    echo "--- 3. 새 버전 배포 및 링크 전환 시작 ---"
    NEW_APP_DIR="${WEB_APP_DEST_BASE_DIR}/nobrain-server_$(date +"%Y%m%d%H%M%S")" # 타임스탬프 기반 새 디렉토리 이름

    echo "새 앱 디렉토리 생성 및 빌드된 파일 복사: ${NEW_APP_DIR}"
    sudo mkdir -p "$NEW_APP_DIR"
    sudo rsync -az --exclude '.git/' "${BUILD_DIR}/" "$NEW_APP_DIR/" # .git 디렉토리 제외하고 복사
    if [ $? -eq 0 ]; then
        echo "빌드된 파일 복사 성공."
    else
        echo "오류: 빌드된 파일 복사에 실패했습니다."
        return 1
    fi

    echo "새 앱 디렉토리 소유권 및 권한 설정: ${NEW_APP_DIR}"
    sudo chown -R www-data:www-data "$NEW_APP_DIR"
    sudo chmod -R 755 "$NEW_APP_DIR"

    # --- 로그 디렉토리 관련 사항 제거됨 ---

    echo "심볼릭 링크 전환: ${WEB_APP_LINK_NAME} -> ${NEW_APP_DIR}"
    # 새 심볼릭 링크를 임시로 만들고, 기존 링크를 교체 (atomic operation)
    sudo ln -sfn "$NEW_APP_DIR" "${WEB_APP_LINK_NAME}_new"
    sudo mv -T "${WEB_APP_LINK_NAME}_new" "$WEB_APP_LINK_NAME"

    if [ $? -eq 0 ]; then
        echo "심볼릭 링크 전환 성공."
    else
        echo "오류: 심볼릭 링크 전환에 실패했습니다."
        return 1
    fi

    echo "--- 3. 새 버전 배포 및 링크 전환 완료 ---"
    return 0
}

# PM2 앱 시작/재시작/종료 함수
manage_pm2_app() {
    local action=$1
    echo "--- 4. PM2 앱 $action 시작 ---"

    local CURRENT_APP_PATH=""
    if [ -L "$WEB_APP_LINK_NAME" ]; then
        CURRENT_APP_PATH="$(readlink -f "$WEB_APP_LINK_NAME")" # 심볼릭 링크가 가리키는 실제 경로
    fi

    if [ -z "$CURRENT_APP_PATH" ] && [ "$action" != "stop" ]; then
        echo "오류: 현재 활성화된 앱 경로를 찾을 수 없습니다. (WEB_APP_LINK_NAME 확인)"
        return 1
    fi

    # stop 명령은 현재 경로가 필요 없을 수 있으므로 예외 처리
    if [ "$action" != "stop" ]; then
        if [ ! -d "$CURRENT_APP_PATH" ]; then
            echo "오류: 앱 경로 '${CURRENT_APP_PATH}'가 유효한 디렉토리가 아닙니다."
            return 1
        fi
        cd "$CURRENT_APP_PATH" || { echo "오류: ${CURRENT_APP_PATH}로 이동할 수 없습니다."; return 1; }
    fi

    case "$action" in
        "start")
            echo "PM2로 ${PM2_APP_NAME} 앱 시작 중... (PATH: ${CURRENT_APP_PATH})"
            sudo pm2 start ecosystem.config.js --name "$PM2_APP_NAME" --env "${NODE_ENV_PROD}"
            if [ $? -eq 0 ]; then
                echo "PM2 앱 ${PM2_APP_NAME} 시작 성공."
                sudo pm2 save # PM2 목록 저장 (재부팅 시 자동 시작을 위해)
            else
                echo "오류: PM2 앱 ${PM2_APP_NAME} 시작에 실패했습니다."
                return 1
            fi
            ;;
        "stop")
            echo "PM2로 ${PM2_APP_NAME} 앱 종료 중..."
            sudo pm2 stop "$PM2_APP_NAME"
            if [ $? -eq 0 ]; then
                echo "PM2 앱 ${PM2_APP_NAME} 종료 성공."
                sudo pm2 save
            else
                echo "경고: PM2 앱 ${PM2_APP_NAME} 종료에 실패했거나 이미 실행 중이지 않습니다."
            fi
            ;;
        "restart")
            echo "PM2로 ${PM2_APP_NAME} 앱 재시작 중... (PATH: ${CURRENT_APP_PATH})"
            sudo pm2 restart ecosystem.config.js --name "$PM2_APP_NAME" --env "${NODE_ENV_PROD}"
            if [ $? -eq 0 ]; then
                echo "PM2 앱 ${PM2_APP_NAME} 재시작 성공."
            else
                echo "오류: PM2 앱 ${PM2_APP_NAME} 재시작에 실패했습니다."
                return 1
            fi
            ;;
        *)
            echo "오류: 알 수 없는 PM2 명령 '$action'"
            return 1
            ;;
    esac
    echo "--- 4. PM2 앱 $action 완료 ---"
    return 0
}

# --- 명령 처리 ---
case "$COMMAND" in
    "start")
        manage_pm2_app "start"
        ;;
    "restart")
        manage_pm2_app "restart"
        ;;
    "stop")
        manage_pm2_app "stop"
        ;;
    "patch")
        # 1. 기존 앱 백업
        backup_current_app || exit 1

        # 2. Git 클론 및 빌드 (다운타임 없이 준비)
        clone_and_build || exit 1

        # 3. 새 버전 배포 및 심볼릭 링크 전환
        deploy_new_version || exit 1

        # 4. PM2 앱 재시작 (새로운 심볼릭 링크를 바라보도록)
        manage_pm2_app "restart"
        ;;
    *)
        echo "오류: 유효하지 않은 명령입니다. [start|stop|patch] 중 하나를 사용하세요."
        exit 1
        ;;
esac

echo "========================================"
echo " 스크립트 실행 종료!"
echo "========================================"
