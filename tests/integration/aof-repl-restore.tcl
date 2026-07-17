source tests/support/aofmanifest.tcl
tags {"aof-repl-restore external:skip"} {
    
    test "AOF replication state: primary replid and reploff are restored and allow PSYNC" {
        start_server {tags {"repl"} overrides {appendonly yes appendfsync always aof-replication-restore yes}} {
            set primary [srv 0 client]
            set primary_host [srv 0 host]
            set primary_port [srv 0 port]

            start_server {overrides {appendonly yes appendfsync always aof-replication-restore yes}} {
                set replica [srv 0 client]
                set replica_id 0

                $replica replicaof $primary_host $primary_port
                wait_for_condition 50 100 {
                    [status $replica master_link_status] == "up"
                } else {
                    fail "Replica could not connect to primary"
                }

                # Initial full sync
                assert_equal 1 [status $primary sync_full]

                # Write some data
                for {set j 0} {$j < 100} {incr j} {
                    $primary set key_$j val_$j
                }
                wait_for_ofs_sync $primary $replica

                set original_replid [status $primary master_replid]
                set original_offset [status $primary master_repl_offset]

                # Restart primary and see if replica can partial resync
                set log_lines [count_log_lines $replica_id]
                restart_server -1 true false true now
                set primary [srv -1 client]
                
                # Wait for primary to come up and replica to reconnect
                wait_for_condition 100 100 {
                    [status $replica master_link_status] == "up"
                } else {
                    fail "Replica could not reconnect to primary"
                }

                # Check if it was a partial resync
                wait_for_log_messages $replica_id {"*Partial Resynchronization*"} $log_lines 100 100
                assert_equal 1 [status $primary sync_partial_ok]
                assert_equal $original_replid [status $primary master_replid2]
                assert_equal [expr $original_offset + 1] [status $primary second_repl_offset]
            }
        }
    }

    test "AOF replication state: replica restored from AOF can partial resync" {
        start_server {tags {"repl"} overrides {appendonly yes appendfsync always aof-replication-restore yes}} {
            set primary [srv 0 client]
            set primary_host [srv 0 host]
            set primary_port [srv 0 port]

            start_server [list overrides [list appendonly yes appendfsync always aof-replication-restore yes replicaof "$primary_host $primary_port"]] {
                set replica [srv 0 client]
                set replica_id 0

                wait_for_condition 50 100 {
                    [status $replica master_link_status] == "up"
                } else {
                    fail "Replica could not connect"
                }

                # 1. Write key1
                $primary set key1 val1
                wait_for_ofs_sync $primary $replica
                
                # 2. AOF Rewrite on replica
                $replica bgrewriteaof
                waitForBgrewriteaof $replica
                
                # 3. Write key2 and ensure sync
                $primary set key2 val2
                wait_for_ofs_sync $primary $replica
                
                # 4. Record state and restart replica
                set original_replid [status $replica master_replid]
                set offset_before_restart [status $replica master_repl_offset]
                
                restart_server 0 true false true now
                set replica [srv 0 client]

                set restored_replid [status $replica master_replid]
                set restored_offset [status $replica master_repl_offset]
                
                puts "Restored offset: $restored_offset (was $offset_before_restart)"

                assert_equal $original_replid $restored_replid
                assert {$restored_offset >= $offset_before_restart}

                # 5. Write key3 while replica is disconnected
                $primary set key3 val3
                
                # 6. Reconnect replica
                $replica replicaof $primary_host $primary_port
                
                # Wait for primary to process PSYNC
                wait_for_condition 200 100 {
                    [status $primary sync_partial_ok] >= 1
                } else {
                    puts "Primary sync_partial_ok: [status $primary sync_partial_ok]"
                    puts "Primary sync_full: [status $primary sync_full]"
                    fail "Replica could not partial resync"
                }
                
                # 7. Verify final data
                # We use a manual loop instead of wait_for_ofs_sync to be more robust
                wait_for_condition 100 100 {
                    [$replica get key3] eq "val3"
                } else {
                    fail "Data did not propagate after partial sync"
                }

                assert_equal "val1" [$replica get key1]
                assert_equal "val2" [$replica get key2]
                assert_equal "val3" [$replica get key3]
            }
        }
    }

    test "AOF replication state: independent of aof-integrity-check" {
        # Scenario 1: Only restore-state enabled
        set sp [tmpdir server.aof-repl-restore-only]
        start_server [list overrides [list dir $sp appendonly yes appendfsync always aof-replication-restore yes aof-integrity-check no]] {
            set rd [valkey [srv host] [srv port] 0 $::tls]
            set original_replid [status $rd master_replid]
            $rd set a 1
            
            set ai [get_last_incr_aof_path $rd]
            set fp [open $ai r]
            set content [read $fp]
            close $fp
            
            assert_match "*#HDR:v1;replid:$original_replid;reploff:*" $content
            assert_no_match "*len:*" $content
            assert_no_match "*checksum:*" $content
        }

        # Scenario 2: Only integrity-check enabled
        set sp [tmpdir server.aof-integrity-only]
        start_server [list overrides [list dir $sp appendonly yes appendfsync always aof-replication-restore no aof-integrity-check yes aof-use-rdb-preamble yes]] {
            set rd [valkey [srv host] [srv port] 0 $::tls]
            $rd set a 1
            
            set ai [get_last_incr_aof_path $rd]
            set fp [open $ai r]
            set content [read $fp]
            close $fp
            
            assert_match "*#HDR:v1;len:*;checksum:*" $content
            assert_no_match "*replid:*" $content
            assert_no_match "*reploff:*" $content
        }
    }

    test "AOF manifest contains per-file replid and reploff when replication restore is enabled" {
        set sp [tmpdir server.aof-repl-restore-manifest]
        start_server [list overrides [list dir $sp appendonly yes appendfsync always aof-replication-restore yes aof-use-rdb-preamble yes]] {
            set rd [valkey [srv host] [srv port] 0 $::tls]
            $rd set foo bar
            $rd bgrewriteaof
            waitForBgrewriteaof $rd

            set manifest_path [file join [dict get [srv config] dir] "appendonlydir" "appendonly.aof.manifest"]
            set fp [open $manifest_path r]
            set content [read $fp]
            close $fp

            assert_match "*file * seq * type b *replid * reploff *" $content
        }
    }
}
