#!/bin/bash
# Configuration
MEMTIER_REDIS_TLS='y'
MEMTIER_DRAGONFLY_TLS='y'
CLEANUP='n' # Set to 'y' to cleanup containers after benchmarks, 'n' to keep them running
USE_DOCKER_COMPOSE=true
CPUS=$(nproc)

# Port Configuration
REDIS_HOST_PORT=6377
DRAGONFLY_HOST_PORT=6381
REDIS_TLS_HOST_PORT=6390
DRAGONFLY_TLS_HOST_PORT=6392

update_docker_compose_cpuset() {
    echo "==== Updating Docker Compose CPU Sets ===="
    local total_cores=$CPUS
    local physical_cores=$((CPUS / 2)) # Assuming hyperthreading
    echo "Detected: $total_cores logical cores, $physical_cores physical cores"
    
    # Strategy 2: Use all logical cores (for maximum performance)
    local cpuset_all="0-$((total_cores - 1))"
    echo "Setting cpuset to: $cpuset_all"
    
    # Update docker-compose.yml
    if [ -f "docker-compose.yml" ]; then
        sed -i "s/cpuset: \"[^\"]*\"/cpuset: \"$cpuset_all\"/g" docker-compose.yml
        echo "✅ Updated docker-compose.yml cpuset to: $cpuset_all"
    else
        echo "⚠️ docker-compose.yml not found"
    fi
}

set -e # Exit on any error

get_docker_compose_cmd() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    elif docker compose version &> /dev/null 2>&1; then
        echo "docker compose"
    else
        echo "ERROR: Neither docker-compose nor docker compose found" >&2
        exit 1
    fi
}

# Set the compose command globally
COMPOSE_CMD=$(get_docker_compose_cmd)

echo "=================================="
echo "REDIS VS DRAGONFLY BENCHMARK SUITE"
echo "Configuration: CLEANUP=$CLEANUP, USE_DOCKER_COMPOSE=$USE_DOCKER_COMPOSE"
echo "Docker Compose Command: $COMPOSE_CMD"
echo "Port Configuration: Redis=${REDIS_HOST_PORT}, Dragonfly=${DRAGONFLY_HOST_PORT}"
echo "=================================="

# System Information
print_system_info() {
    echo "==== System Information ===="
    echo "Kernel: $(uname -r)"
    echo "CPU Count: $CPUS"
    echo "==== CPU Info ===="
    lscpu
    echo "==== Memory Info ===="
    free -m
    echo "==== Disk Info ===="
    df -hT
}

# Setup directories and certificates
setup_environment() {
    echo "==== Setting Up Environment ===="
    mkdir -p benchmarklogs tls
    
    # Generate SSL certificates
    pushd tls
    echo "Generating SSL certificates..."
    
    # CA certificate
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ca.key
    openssl req -new -x509 -days 365 -key ca.key -out ca.crt \
        -subj "/C=US/ST=Some-State/O=OrganizationName/OU=OrganizationalUnit/CN=CA"
    
    # Server certificate
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out test.key
    openssl req -new -key test.key -out test.csr \
        -subj "/C=US/ST=Some-State/O=OrganizationName/OU=OrganizationalUnit/CN=test.com"
    openssl x509 -req -in test.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out test.crt -days 365
    
    # Client certificate
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out client_priv.pem
    openssl req -new -key client_priv.pem -out client.csr \
        -subj "/C=US/ST=Some-State/O=OrganizationName/OU=OrganizationalUnit/CN=test.server.com"
    openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out client_cert.pem -days 365
    
    ls -lAhrt
    popd
    
    # Copy certificates to main directory
    cp tls/* .
}

# Update configurations
update_configurations() {
    echo "==== Updating Configurations ===="
    update_docker_compose_cpuset
    
    # Non-TLS configurations
    cat >> redis.conf << EOF
io-threads $CPUS
io-threads-do-reads yes
save ""
appendonly no
protected-mode no
EOF

    # TLS configurations
    cat >> redis-tls.conf << EOF
io-threads $CPUS
io-threads-do-reads yes
tls-port 6390
tls-cert-file /tls/test.crt
tls-key-file /tls/test.key
tls-ca-cert-file /tls/ca.crt
save ""
appendonly no
protected-mode no
EOF

    cat >> dragonfly-tls.conf << EOF
--proactor_threads=$CPUS
--port=6392
--tls_cert_file=/tls/test.crt
--tls_key_file=/tls/test.key
--tls_ca_cert_file=/tls/ca.crt
--dbfilename=''
EOF

    # Update Dragonfly Dockerfiles
    sed -i "s|--proactor_threads=2|--proactor_threads=$CPUS|" Dockerfile-dragonfly
    sed -i "s|--proactor_threads=2|--proactor_threads=$CPUS|" Dockerfile-dragonfly-tls
}

# Check container status
check_container_status() {
    local service_name=$1
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        local container_id
        container_id=$($COMPOSE_CMD ps -q "$service_name" 2>/dev/null)
        if [ -n "$container_id" ]; then
            local running_state
            running_state=$(docker inspect --format='{{.State.Running}}' "$container_id" 2>/dev/null)
            if [ "$running_state" = "true" ]; then
                return 0
            fi
        fi
        return 1
    else
        if docker ps --format '{{.Names}}' | grep -q "^${service_name}$"; then
            return 0
        else
            return 1
        fi
    fi
}

# Check all containers status
check_all_containers_status() {
    echo "==== Checking Container Status ===="
    local services=("redis" "dragonfly" "redis-tls" "dragonfly-tls")
    local running_count=0
    local total_count=${#services[@]}
    
    for service in "${services[@]}"; do
        set +e
        if check_container_status "$service"; then
            echo "✅ $service is running"
            ((running_count++))
        else
            echo "❌ $service is not running"
        fi
        set -e
    done
    
    echo "Status: $running_count/$total_count containers running"
    
    if [ $running_count -eq $total_count ]; then
        echo "ℹ️ All containers are already running"
        return 0
    elif [ $running_count -gt 0 ]; then
        echo "⚠️ Some containers are running, some are not"
        return 2
    else
        echo "ℹ️ No containers are running"
        return 1
    fi
}

# Docker management functions
build_containers() {
    echo "==== Building Docker Images ===="
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "Building with Docker Compose using: $COMPOSE_CMD"
        $COMPOSE_CMD build --parallel
    else
        echo "Building with Docker..."
        docker build -t redis:latest -f Dockerfile-redis .
        docker build -t dragonfly:latest -f Dockerfile-dragonfly .
        docker build -t redis-tls:latest -f Dockerfile-redis-tls .
        docker build -t dragonfly-tls:latest -f Dockerfile-dragonfly-tls-nopass .
    fi
    docker images | grep -E 'redis|dragonfly'
}

# Smart container startup
start_containers() {
    echo "==== Managing Container Startup ===="
    
    check_all_containers_status
    local status=$?
    
    if [ $status -eq 0 ]; then
        echo "ℹ️ All containers already running, skipping startup"
        if [ "$CLEANUP" = [nN] ]; then
            echo "ℹ️ CLEANUP=n: Will reuse existing containers"
            return 0
        else
            echo "⚠️ CLEANUP=y: Will restart containers for fresh state"
            stop_containers
        fi
    elif [ $status -eq 2 ]; then
        echo "⚠️ Partial container state detected"
        if [ "$CLEANUP" = [nN] ]; then
            echo "ℹ️ CLEANUP=n: Starting missing containers only"
        else
            echo "⚠️ CLEANUP=y: Restarting all containers for consistency"
            stop_containers
        fi
    fi
    
    if [ $status -ne 0 ] || [ "$CLEANUP" = [yY] ]; then
        echo "Restarting Docker service..."
        # systemctl restart docker
        sleep 5
    fi
    
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "Starting containers with Docker Compose using: $COMPOSE_CMD"
        $COMPOSE_CMD up -d
        sleep 30
    else
        echo "Starting containers individually..."
        local services=(
            "redis:redis:${REDIS_HOST_PORT}:6379"
            "dragonfly:dragonfly:${DRAGONFLY_HOST_PORT}:6379"
            "redis-tls:redis-tls:${REDIS_TLS_HOST_PORT}:6390"
            "dragonfly-tls:dragonfly-tls:${DRAGONFLY_TLS_HOST_PORT}:6392"
        )
        
        for service_info in "${services[@]}"; do
            IFS=':' read -r container_name image_name host_port container_port <<< "$service_info"
            if ! check_container_status "$container_name"; then
                echo "Starting $container_name..."
                docker run --name "$container_name" -d -p "${host_port}:${container_port}" \
                    --cpuset-cpus="0-3" --ulimit memlock=-1 "${image_name}:latest"
            else
                echo "✅ $container_name already running"
            fi
        done
        sleep 30
    fi
    
    check_all_containers_status
}

# Stop containers function
stop_containers() {
    echo "==== Stopping Containers ===="
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "Stopping containers with Docker Compose using: $COMPOSE_CMD"
        $COMPOSE_CMD down --remove-orphans
    else
        echo "Stopping individual containers..."
        local services=("redis" "dragonfly" "redis-tls" "dragonfly-tls")
        for service in "${services[@]}"; do
            if check_container_status "$service"; then
                echo "Stopping $service..."
                docker stop "$service" 2>/dev/null || true
                docker rm "$service" 2>/dev/null || true
            fi
        done
    fi
}

# CSF Firewall management
manage_csf_firewall() {
    echo "==== Managing CSF Firewall ===="
    for service in redis dragonfly redis-tls dragonfly-tls; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $service 2>/dev/null)
            if [ ! -z "$CONTAINER_IP" ]; then
                echo "Adding $service ($CONTAINER_IP) to CSF allow list"
                csf -a $CONTAINER_IP $service || echo "Warning: Could not add $CONTAINER_IP to CSF"
            fi
        fi
    done
}

# Database connectivity tests
test_connectivity() {
    echo "==== Testing Database Connectivity ===="
    echo "Waiting for databases to initialize..."
    sleep 10
    
    # Non-TLS tests
    echo "Testing Redis..."
    docker exec redis redis-cli -h 127.0.0.1 -p 6379 PING || echo "Redis connection failed"
    
    echo "Testing Dragonfly..."
    docker exec dragonfly redis-cli -h 127.0.0.1 -p 6379 PING || echo "Dragonfly connection failed"
    
    # TLS tests
    if [[ "$MEMTIER_REDIS_TLS" = [yY] ]]; then
        echo "Testing Redis TLS..."
        docker exec redis-tls redis-cli -h 127.0.0.1 -p 6390 --tls --insecure \
            --cert /tls/test.crt --key /tls/test.key --cacert /tls/ca.crt PING || echo "Redis TLS connection failed"
    fi
    
    if [[ "$MEMTIER_DRAGONFLY_TLS" = [yY] ]]; then
        echo "Testing Dragonfly TLS..."
        docker exec dragonfly-tls redis-cli -h 127.0.0.1 -p 6392 --tls \
            --cert /tls/test.crt --key /tls/test.key --cacert /tls/ca.crt PING || echo "Dragonfly TLS connection failed"
    fi
}

# Display container information
show_container_info() {
    echo "=================================="
    echo "CONTAINER INFORMATION FOR TESTING"
    echo "=================================="
    echo ""
    echo "Container Status:"
    docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}" | grep -E "(redis|dragonfly)"
    echo ""
    echo "Connection Commands:"
    echo "Non-TLS:"
    echo "  Redis: docker exec -it redis redis-cli -h 127.0.0.1 -p 6379"
    echo "  Dragonfly: docker exec -it dragonfly redis-cli -h 127.0.0.1 -p 6379"
    echo ""
    echo "TLS:"
    echo "  Redis TLS: docker exec -it redis-tls redis-cli -h 127.0.0.1 -p 6390 --tls --insecure --cert /tls/test.crt --key /tls/test.key --cacert /tls/ca.crt"
    echo "  Dragonfly TLS: docker exec -it dragonfly-tls redis-cli -h 127.0.0.1 -p 6392 --tls --cert /tls/test.crt --key /tls/test.key --cacert /tls/ca.crt"
    echo ""
    echo "Host Connections:"
    echo "  Redis: redis-cli -h 127.0.0.1 -p $REDIS_HOST_PORT"
    echo "  Dragonfly: redis-cli -h 127.0.0.1 -p $DRAGONFLY_HOST_PORT"
    echo ""
    echo "Container Management:"
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "  Stop all: $COMPOSE_CMD down"
        echo "  Start all: $COMPOSE_CMD up -d"
        echo "  Logs: $COMPOSE_CMD logs [service_name]"
        echo "  Status: $COMPOSE_CMD ps"
    else
        echo "  Stop all: docker stop redis dragonfly redis-tls dragonfly-tls"
        echo "  Remove all: docker rm redis dragonfly redis-tls dragonfly-tls"
        echo "  Logs: docker logs [container_name]"
    fi
    echo ""
    echo "Manual cleanup when done:"
    echo "  ./redis-benchmark.sh cleanup"
    echo "=================================="
}

# Benchmark execution
run_memtier_benchmark() {
    local host=$1
    local port=$2
    local threads=$3
    local output_file=$4
    local tls_opts=$5
    local cpu_affinity=$6
    
    echo "==== Flushing DB on $host:$port ===="
    if [ -z "$tls_opts" ]; then
        redis-cli -h "$host" -p "$port" FLUSHALL
    else
        redis-cli -h "$host" -p "$port" $tls_opts FLUSHALL
    fi
    
    echo "==== Running benchmark: $output_file ===="
    local cmd="memtier_benchmark -s $host --ratio=1:15 -p $port --protocol=redis \
        -t $threads --distinct-client-seed --hide-histogram --requests=2000 \
        --clients=100 --pipeline=1 --data-size=384 \
        --key-pattern=G:G --key-minimum=1 --key-maximum=1000000 \
        --key-median=500000 --key-stddev=166667 $tls_opts"
    
    eval "$cmd | tee $output_file" || echo "Benchmark failed: $output_file"
}

# Main benchmark execution
run_benchmarks() {
    echo "==== Running Benchmarks ===="
    
    declare -A cpu_affinities=(
        [1]="0"
        [2]="0,1"
        [4]="0,1,2,3"
        [8]=""
    )
    
    # Non-TLS benchmarks
    for threads in 1 2 4 8; do
        cpu_affinity=${cpu_affinities[$threads]}
        
        # Redis
        run_memtier_benchmark "127.0.0.1" "$REDIS_HOST_PORT" "$threads" \
            "./benchmarklogs/redis_benchmarks_${threads}threads.txt" "" "$cpu_affinity"
        
        # Dragonfly
        run_memtier_benchmark "127.0.0.1" "$DRAGONFLY_HOST_PORT" "$threads" \
            "./benchmarklogs/dragonfly_benchmarks_${threads}threads.txt" "" "$cpu_affinity"
    done
    
    # TLS benchmarks
    if [[ "$MEMTIER_REDIS_TLS" = [yY] ]] || [[ "$MEMTIER_DRAGONFLY_TLS" = [yY] ]]; then
        for threads in 1 2 4 8; do
            cpu_affinity=${cpu_affinities[$threads]}
            
            if [[ "$MEMTIER_REDIS_TLS" = [yY] ]]; then
                run_memtier_benchmark "127.0.0.1" "$REDIS_TLS_HOST_PORT" "$threads" \
                    "./benchmarklogs/redis_benchmarks_${threads}threads_tls.txt" \
                    "--tls --cert=${PWD}/test.crt --key=${PWD}/test.key --cacert=${PWD}/ca.crt --tls-skip-verify" \
                    "$cpu_affinity"
            fi
            
            if [[ "$MEMTIER_DRAGONFLY_TLS" = [yY] ]]; then
                run_memtier_benchmark "127.0.0.1" "$DRAGONFLY_TLS_HOST_PORT" "$threads" \
                    "./benchmarklogs/dragonfly_benchmarks_${threads}threads_tls.txt" \
                    "--tls --cert=${PWD}/client_cert.pem --key=${PWD}/client_priv.pem --cacert=${PWD}/ca.crt" \
                    "$cpu_affinity"
            fi
        done
    fi
}

# Process results
process_results() {
    echo "==== Processing Results ===="
    
    for db in redis dragonfly; do
        for threads in 1 2 4 8; do
            # Non-TLS
            if [ -f "./benchmarklogs/${db}_${threads}threads.txt" ]; then
                python3 scripts/parse_memtier_to_md.py \
                    "./benchmarklogs/${db}_${threads}threads.txt" \
                    "$(echo "$db" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') $threads Thread$([ $threads -gt 1 ] && echo 's')"
            fi
            
            # TLS
            if [ -f "./benchmarklogs/${db}_${threads}threads_tls.txt" ]; then
                python3 scripts/parse_memtier_to_md.py \
                    "./benchmarklogs/${db}_${threads}threads_tls.txt" \
                    "$(echo ${db^}) TLS $threads Thread$([ $threads -gt 1 ] && echo 's')"
            fi
        done
    done
    
    # Combine results
    for db in redis dragonfly; do
        files=""
        for threads in 1 2 4 8; do
            if [ -f "./benchmarklogs/${db}_${threads}threads.md" ]; then
                files="$files ./benchmarklogs/${db}_${threads}threads.md"
            fi
        done
        if [ ! -z "$files" ]; then
            python3 scripts/combine_markdown_results.py "$files" "${db}"
        fi
        
        # TLS
        tls_files=""
        for threads in 1 2 4 8; do
            if [ -f "./benchmarklogs/${db}_${threads}threads_tls.md" ]; then
                tls_files="$tls_files ./benchmarklogs/${db}_${threads}threads_tls.md"
            fi
        done
        if [ ! -z "$tls_files" ]; then
            python3 scripts/combine_markdown_results.py "$tls_files" "${db}-tls"
        fi
    done
    
    # Create final combined files
    cat ./benchmarklogs/combined_*_results.md > ./combined_all_results.md 2>/dev/null || true
    cat ./benchmarklogs/combined_*-tls_results.md > ./combined_all_results_tls.md 2>/dev/null || true
}

# Generate charts
generate_charts() {
    echo "==== Generating Charts ===="
    if command -v python3 &> /dev/null && python3 -c "import matplotlib" 2>/dev/null; then
        if [ -f "./combined_all_results.md" ]; then
            python3 scripts/latency-charts.py combined_all_results.md nonTLS || echo "Chart generation failed"
            python3 scripts/opssec-charts.py combined_all_results.md nonTLS || echo "Chart generation failed"
        fi
        
        if [ -f "./combined_all_results_tls.md" ]; then
            python3 scripts/latency-charts.py combined_all_results_tls.md TLS || echo "TLS chart generation failed"
            python3 scripts/opssec-charts.py combined_all_results_tls.md TLS || echo "TLS chart generation failed"
        fi
    else
        echo "Python3 or matplotlib not available, skipping chart generation"
    fi
}

# Cleanup function
cleanup() {
    if [ "$CLEANUP" = [yY] ]; then
        echo "==== Cleaning Up (CLEANUP=y) ===="
        if [ "$USE_DOCKER_COMPOSE" = true ]; then
            $COMPOSE_CMD down --remove-orphans
            $COMPOSE_CMD rm -f
        else
            docker stop redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
            docker rm redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
        fi
        docker rmi redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
        docker system prune -f
        echo "✅ Cleanup completed"
    else
        echo "==== Skipping Cleanup (CLEANUP=n) ===="
        echo "ℹ️ Containers left running for manual testing"
        show_container_info
    fi
}

# Enhanced manual cleanup function
manual_cleanup() {
    echo "==== Enhanced Manual Cleanup ===="
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "Stopping Docker Compose services..."
        $COMPOSE_CMD down --remove-orphans --volumes
        $COMPOSE_CMD rm -f
        
        echo "Removing Docker Compose images..."
        docker rmi redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
        docker rmi redis-comparison-benchmarks-redis:latest 2>/dev/null || true
        docker rmi redis-comparison-benchmarks-dragonfly:latest 2>/dev/null || true
        docker rmi redis-comparison-benchmarks-redis-tls:latest 2>/dev/null || true
        docker rmi redis-comparison-benchmarks-dragonfly-tls:latest 2>/dev/null || true
        echo "Docker Compose cleanup completed"
    else
        echo "Stopping and removing containers..."
        docker stop redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
        docker rm redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
        
        echo "Removing images..."
        docker rmi redis dragonfly redis-tls dragonfly-tls 2>/dev/null || true
    fi
    
    echo "Cleaning build cache..."
    docker builder prune -f
    
    echo "Final cleanup - removing any dangling images..."
    docker image prune -f
    
    echo "✅ Enhanced cleanup completed"
    echo ""
    echo "Verification:"
    echo "Remaining images:"
    docker images | grep -E 'redis|dragonfly' || echo "  No benchmark images found ✅"
    echo ""
    echo "Docker system space reclaimed:"
    docker system df
}

# Main execution
main() {
    print_system_info
    setup_environment
    update_configurations
    build_containers
    start_containers
    manage_csf_firewall
    test_connectivity
    run_benchmarks
    process_results
    generate_charts
    cleanup
    
    echo "=================================="
    echo "BENCHMARK PROCESS COMPLETED"
    echo "=================================="
    echo "Results available in:"
    echo "  - ./benchmarklogs/ (individual results)"
    echo "  - ./combined_all_results.md (non-TLS summary)"
    echo "  - ./combined_all_results_tls.md (TLS summary)"
    echo "  - *.png (charts, if generated)"
    
    if [ "$CLEANUP" = [nN] ]; then
        echo ""
        echo "🚀 Containers are still running for your testing!"
        echo "Use './redis-benchmark.sh cleanup' when done"
    fi
}

# Standalone start function
standalone_start() {
    echo "==== Standalone Container Start ===="
    
    if [ ! -f "docker-compose.yml" ] && [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "⚠️ No docker-compose.yml found, setting up environment first..."
        setup_environment
        update_configurations
    fi
    
    if [ "$USE_DOCKER_COMPOSE" = true ] && [ -f "docker-compose.yml" ]; then
        echo "🔧 Ensuring cpuset matches current hardware..."
        update_docker_compose_cpuset
    fi
    
    echo "Checking if images exist..."
    if [ "$USE_DOCKER_COMPOSE" = true ]; then
        declare -A image_mappings=(
            ["redis:latest"]="redis-comparison-benchmarks-redis:latest"
            ["dragonfly:latest"]="redis-comparison-benchmarks-dragonfly:latest"
            ["redis-tls:latest"]="redis-comparison-benchmarks-redis-tls:latest"
            ["dragonfly-tls:latest"]="redis-comparison-benchmarks-dragonfly-tls:latest"
        )
        local required_images=("redis:latest" "dragonfly:latest" "redis-tls:latest" "dragonfly-tls:latest")
    else
        local required_images=("redis:latest" "dragonfly:latest" "redis-tls:latest" "dragonfly-tls:latest")
    fi
    
    local missing_images=()
    for image in "${required_images[@]}"; do
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$"; then
            echo "✅ Found image: $image"
        else
            echo "❌ Missing image: $image"
            missing_images+=("$image")
        fi
    done
    
    if [ "$USE_DOCKER_COMPOSE" = true ] && [ ${#missing_images[@]} -gt 0 ]; then
        echo ""
        echo "Tagging Docker Compose generated images..."
        local tagged_count=0
        for missing_image in "${missing_images[@]}"; do
            local compose_image="${image_mappings[$missing_image]}"
            if [ -n "$compose_image" ] && docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${compose_image}$"; then
                echo "🏷️ Tagging $compose_image → $missing_image"
                if docker tag "$compose_image" "$missing_image"; then
                    echo "✅ Successfully tagged $missing_image"
                    tagged_count=$((tagged_count + 1))
                else
                    echo "❌ Failed to tag $missing_image"
                fi
            else
                echo "❌ Compose image not found: $compose_image"
            fi
        done
        
        echo ""
        echo "✅ Tagged $tagged_count/${#missing_images[@]} images"
        
        missing_images=()
        for image in "${required_images[@]}"; do
            if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$"; then
                missing_images+=("$image")
            fi
        done
    fi
    
    if [ ${#missing_images[@]} -gt 0 ]; then
        echo ""
        echo "Still missing ${#missing_images[@]} images, building them..."
        echo "Missing: ${missing_images[*]}"
        build_containers
        
        if [ "$USE_DOCKER_COMPOSE" = true ]; then
            echo "Tagging newly built images..."
            for missing_image in "${missing_images[@]}"; do
                local compose_image="${image_mappings[$missing_image]}"
                if [ -n "$compose_image" ] && docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${compose_image}$"; then
                    docker tag "$compose_image" "$missing_image" || echo "Warning: Failed to tag $missing_image"
                fi
            done
        fi
    fi
    
    echo ""
    echo "✅ All images ready - proceeding to start containers"
    echo ""
    echo "🚀 Starting all containers with Docker Compose..."
    
    echo "Stopping any existing containers..."
    $COMPOSE_CMD down --remove-orphans 2>/dev/null || true
    
    echo "Starting containers..."
    if $COMPOSE_CMD up -d; then
        echo "✅ Docker Compose startup completed"
    else
        echo "❌ Docker Compose startup failed"
        echo "Checking logs..."
        $COMPOSE_CMD logs --tail=20
        return 1
    fi
    
    echo "Waiting for containers to initialize..."
    sleep 15
    
    echo ""
    echo "Container status:"
    $COMPOSE_CMD ps
    
    local running_containers=$($COMPOSE_CMD ps -q | wc -l)
    if [ "$running_containers" -eq 0 ]; then
        echo ""
        echo "❌ No containers are running! Debugging..."
        echo ""
        echo "Docker Compose services status:"
        $COMPOSE_CMD ps -a
        echo ""
        echo "Recent logs:"
        $COMPOSE_CMD logs --tail=50
        echo ""
        echo "Available images:"
        docker images | grep -E 'redis|dragonfly'
        return 1
    else
        echo ""
        echo "✅ $running_containers containers are running"
    fi
    
    echo ""
    manage_csf_firewall
    test_connectivity
    show_container_info
}

# Standalone stop function
standalone_stop() {
    echo "==== Standalone Container Stop ===="
    
    check_all_containers_status
    local status=$?
    if [ $status -eq 1 ]; then
        echo "ℹ️ No containers are running"
        return 0
    fi
    
    stop_containers
    
    echo "Verifying containers are stopped..."
    check_all_containers_status
}

# Standalone restart function
standalone_restart() {
    echo "==== Standalone Container Restart ===="
    echo "Step 1: Stopping containers..."
    standalone_stop
    echo ""
    echo "Step 2: Starting containers..."
    standalone_start
}

# Enhanced build-only function
standalone_build() {
    echo "==== Standalone Container Build ===="
    
    if [ ! -f "docker-compose.yml" ] && [ "$USE_DOCKER_COMPOSE" = true ]; then
        echo "Setting up environment for build..."
        setup_environment
        update_configurations
    fi
    
    build_containers
    
    echo ""
    echo "✅ Build completed. Available images:"
    docker images | grep -E 'redis|dragonfly' | head -10
}

# Enhanced logs function
show_logs() {
    local service=${1:-""}
    echo "==== Container Logs ===="
    
    if [ ! -z "$service" ]; then
        echo "Showing logs for: $service"
        if [ "$USE_DOCKER_COMPOSE" = true ]; then
            $COMPOSE_CMD logs --tail=50 "$service"
        else
            docker logs --tail=50 "$service"
        fi
    else
        echo "Available containers:"
        local services=("redis" "dragonfly" "redis-tls" "dragonfly-tls")
        for service in "${services[@]}"; do
            if check_container_status "$service"; then
                echo "  ✅ $service (running)"
            else
                echo "  ❌ $service (not running)"
            fi
        done
        echo ""
        echo "Usage: $0 logs [service_name]"
        echo "Example: $0 logs redis"
        echo "For live logs: docker-compose logs -f [service_name]"
    fi
}

# Container shell access
container_shell() {
    local service=${1:-""}
    if [ -z "$service" ]; then
        echo "Usage: $0 shell [service_name]"
        echo "Available services: redis dragonfly redis-tls dragonfly-tls"
        return 1
    fi
    
    if check_container_status "$service"; then
        echo "Connecting to $service container..."
        docker exec -it "$service" /bin/bash || docker exec -it "$service" /bin/sh
    else
        echo "❌ Container $service is not running"
        echo "Start it first with: $0 start"
    fi
}

# Dragonfly benchmark function
dragonfly_benchmark() {
    echo "==== Benchmark: Dragonfly only ===="
    
    if ! check_container_status "dragonfly"; then
        echo "❌ Dragonfly container is not running. Start it first with: $0 start"
        return 1
    fi
    
    mkdir -p benchmarklogs
    
    threads_list=(1 2 4 6 8)
    cpu_affinities=("0" "0,1" "0-3" "0-5" "0-7")
    
    for i in "${!threads_list[@]}"; do
        threads=${threads_list[$i]}
        cpu_affinity=${cpu_affinities[$i]}
        logfile="./benchmarklogs/dragonfly_${threads}threads.txt"
        
        echo "Running Dragonfly benchmark with $threads threads (cpu_affinity=${cpu_affinity}) -> $logfile"
        run_memtier_benchmark "127.0.0.1" "$DRAGONFLY_HOST_PORT" "$threads" "$logfile" "" "$cpu_affinity"
    done
    
    echo "✅ Dragonfly benchmark completed. Results in ./benchmarklogs/"
}

# Redis benchmark function
redis_benchmark() {
    echo "==== Benchmark: Redis only ===="
    
    if ! check_container_status "redis"; then
        echo "❌ Redis container is not running. Start it first with: $0 start"
        return 1
    fi
    
    mkdir -p benchmarklogs
    
    threads_list=(1 2 4 6 8)
    cpu_affinities=("0" "0,1" "0-3" "0-5" "0-7")
    
    for i in "${!threads_list[@]}"; do
        threads=${threads_list[$i]}
        cpu_affinity=${cpu_affinities[$i]}
        logfile="./benchmarklogs/redis_${threads}threads.txt"
        
        echo "Running Redis benchmark with $threads threads (cpu_affinity=${cpu_affinity}) -> $logfile"
        run_memtier_benchmark "127.0.0.1" "$REDIS_HOST_PORT" "$threads" "$logfile" "" "$cpu_affinity"
    done
    
    echo "✅ Redis benchmark completed. Results in ./benchmarklogs/"
}

# Quick benchmark function (both databases)
quick_benchmark() {
    echo "==== Quick Benchmark (1-8 threads) ===="
    
    check_all_containers_status
    local status=$?
    if [ $status -eq 1 ]; then
        echo "❌ No containers running. Start them first with: $0 start"
        return 1
    fi
    
    mkdir -p benchmarklogs
    
    declare -A cpu_affinities=(
        [1]="0"
        [2]="0,1"
        [4]="0-3"
        [6]="0-5"
        [8]="0-7"
    )
    
    for threads in 1 2 4 6 8; do
        cpu_affinity=${cpu_affinities[$threads]}
        echo "Running $threads thread benchmarks cpu_affinity=${cpu_affinity}..."
        
        run_memtier_benchmark "127.0.0.1" "$REDIS_HOST_PORT" "$threads" \
            "./benchmarklogs/redis_${threads}threads.txt" "" "$cpu_affinity"
        
        run_memtier_benchmark "127.0.0.1" "$DRAGONFLY_HOST_PORT" "$threads" \
            "./benchmarklogs/dragonfly_${threads}threads.txt" "" "$cpu_affinity"
    done
    
    echo "✅ Quick benchmark completed. Results in ./benchmarklogs/"
}

# Handle command line arguments
case "${1:-}" in
    "start")
        standalone_start
        exit 0
        ;;
    "stop")
        standalone_stop
        exit 0
        ;;
    "restart")
        standalone_restart
        exit 0
        ;;
    "build")
        standalone_build
        exit 0
        ;;
    "cleanup")
        manual_cleanup
        exit 0
        ;;
    "status")
        check_all_containers_status
        show_container_info
        exit 0
        ;;
    "logs")
        show_logs "${2:-}"
        exit 0
        ;;
    "shell")
        container_shell "${2:-}"
        exit 0
        ;;
    "dragonfly")
        dragonfly_benchmark
        exit 0
        ;;
    "redis")
        redis_benchmark
        exit 0
        ;;
    "quick")
        quick_benchmark
        exit 0
        ;;
    "process_results")
        process_results
        exit 0
        ;;
    "generate_charts")
        generate_charts
        exit 0
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  (none)       Run full benchmark suite"
        echo "  start        Start all containers (builds if needed)"
        echo "  stop         Stop all containers"
        echo "  restart      Restart all containers"
        echo "  build        Build all container images"
        echo "  status       Show container status and connection info"
        echo "  logs         Show logs for all containers"
        echo "  logs <svc>   Show logs for specific service"
        echo "  shell <svc>  Open shell in specific container"
        echo "  dragonfly    Run benchmark (Dragonfly only)"
        echo "  redis        Run benchmark (Redis only)"
        echo "  quick        Run benchmark (Redis + Dragonfly)"
        echo "  process_results   Convert benchmark logs to markdown"
        echo "  generate_charts   Generate charts from results"
        echo "  cleanup      Manually cleanup containers and images"
        echo "  help         Show this help message"
        echo ""
        echo "Services: redis, dragonfly, redis-tls, dragonfly-tls"
        echo ""
        echo "Configuration variables:"
        echo "  CLEANUP=y|n                  Cleanup containers after benchmarks (default: n)"
        echo "  USE_DOCKER_COMPOSE=true|false  Use docker-compose or individual containers"
        echo "  MEMTIER_*_TLS=y|n           Enable/disable TLS testing"
        echo ""
        echo "Port Configuration:"
        echo "  Redis: $REDIS_HOST_PORT, Dragonfly: $DRAGONFLY_HOST_PORT"
        echo "  TLS - Redis: $REDIS_TLS_HOST_PORT, Dragonfly: $DRAGONFLY_TLS_HOST_PORT"
        echo ""
        echo "Examples:"
        echo "  $0              # Run full benchmarks, keep containers"
        echo "  $0 start        # Just start containers"
        echo "  $0 status       # Check container status"
        echo "  $0 logs redis   # Show Redis logs"
        echo "  $0 dragonfly    # Run Dragonfly benchmark"
        echo "  $0 redis        # Run Redis benchmark"
        echo "  $0 quick        # Run benchmark on both"
        echo "  CLEANUP=y $0    # Run benchmarks, cleanup after"
        echo ""
        echo "Docker Compose Command: $COMPOSE_CMD"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac