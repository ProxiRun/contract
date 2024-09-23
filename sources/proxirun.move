module proxirun::proxirun {
    use std::signer;
    use std::signer::address_of;
    use std::option;

    use std::vector;
    use aptos_std::smart_vector;
    use aptos_std::smart_vector::SmartVector;
    use aptos_framework::event;
    use aptos_framework::account::{create_resource_account, SignerCapability, create_signer_with_capability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_std::smart_table::{Self, SmartTable};


    // ---------------- ERROR CODES ----------------
    // 0XX: general
    /// ERROR 000: General - E_UNAUTHORIZED
    const E_UNAUTHORIZED: u64 = 000;
    // 1XX: user balance
    /// ERROR 100: User Balance - E_INSUFFICIENT_DEPOSIT
    const E_INSUFFICIENT_DEPOSIT: u64 = 100;
    /// ERROR 101: User Balance - E_INVALID_WITHDRAWAL
    const E_INVALID_WITHDRAWAL: u64 = 101;
    // 2XX: bid submission
    /// ERROR 200: Bid Submission - E_AUCTION_HAS_ENDED
    const E_AUCTION_HAS_ENDED: u64 = 200;
    /// ERROR 201: Bid Submission - E_CANNOT_MODIFY_BID
    const E_CANNOT_MODIFY_BID: u64 = 201;
    /// ERROR 202: Bid Submission - E_BID_TOO_EXPENSIVE
    const E_BID_TOO_EXPENSIVE: u64 = 202;
    // 3XX: auction finalization
    /// ERROR 300: Auction Finalization - E_AUUCTION_NOT_ENDED
    const E_AUCTION_NOT_ENDED: u64 = 300;
    /// ERROR 301: Auction Finalization - E_AUCTION_ALREADY_FINALIZED
    const E_AUCTION_ALREADY_FINALIZED: u64 = 301;
    // 4XX: Commit errors
    /// ERROR 400: Commit - E_COMMIT_INVALID_STATUS
    const E_COMMIT_INVALID_STATUS: u64 = 400;

    // ---------------- CONSTANTS ----------------
    const BANK_SEED: vector<u8> = b"BANCO";

    // auction status
    /// Auction for the work request is ongoing
    const S_AUCTION_RUNNING: u8 = 0;
    /// Auction for the work request has ended with no successful bidder
    const S_AUCTION_NO_WINNER: u8 = 1;
    /// Auction for the work request has ended with a successful bidder, waiting for worker to commit its work
    const S_WAIT_COMMIT: u8 = 2;
    /// Received commit for the work request
    const S_RECEIVED_COMMIT: u8 = 3;


    // ---------------- TYPE DEFINITIONS ----------------
    struct WorkRequest has store, drop, copy {
        requester: address,
        submission_time: u64,
        max_price: u64
    }

    struct Bid has store, drop, copy {
        bidder: address,
        price: u64
    }

    struct AuctionEntry has store, copy, drop {
        status: u8,
        work_request: WorkRequest,
        bids: vector<Bid>,
        winner: option::Option<Bid>
    }

    struct UserBalanceEntry has store, copy, drop {
        available: u64,
        locked: u64
    }

    // ---------------- RESOURCES ----------------
    struct Config has key {
        admin: address,
        bank_address: address,
        bank_signer: SignerCapability
    }

    struct AuctionSettings has key, copy, drop {
        auction_duration: u64,
    }

    struct AuctionTable has key {
        auction_entries: SmartVector<AuctionEntry>
    }

    struct UserBalanceTable has key {
        user_balances: SmartTable<address, UserBalanceEntry>
    }

    // ---------------- EVENTS ----------------
    #[event]
    struct OnNewWorkRequest has drop, store {
        request_id: u64,
        requester: address,
        max_price: u64,
        time_limit: u64,
    }


    #[event]
    struct OnWorkRequestCompleted has drop, store {
        request_id: u64
    }

    #[event]
    struct OnNewWorkRequestBid has drop, store {
        request_id: u64,
        bidder: address,
        price: u64
    }

    #[event]
    struct OnBidWon has drop, store {
        request_id: u64,
        winner: address,
        bid_price: u64
    }

    #[event]
    struct OnAuctionFailure has drop, store {
        request_id: u64,
    }


    // ---------------- INITIALIZATION ----------------
    fun init_module(account: &signer) {
        let (bank_signer, signer_cap) = create_resource_account(account, BANK_SEED);
        coin::register<AptosCoin>(&bank_signer);

        let config = Config {
            admin: address_of(account),
            bank_address: address_of(&bank_signer),
            bank_signer: signer_cap
        };
        move_to(account, config);

        let user_balance_table = UserBalanceTable {
            user_balances: smart_table::new<address, UserBalanceEntry>(),
        };
        move_to(account, user_balance_table);

        let auction_settings = AuctionSettings { auction_duration: 6000000};  // 6 seconds, in microseconds
        move_to(account, auction_settings);

        let auction_table = AuctionTable {
            auction_entries: smart_vector::empty_with_config<AuctionEntry>(64, 64),
        };
        move_to(account, auction_table);

    }

    // ---------------- MODIFIERS ----------------
    fun only_admin(account: &signer) acquires Config {
        let config = borrow_global<Config>(@proxirun);
        if (address_of(account) != config.admin) {
            abort E_UNAUTHORIZED
        };
    }


    // ---------------- ENTRYPOINTS ----------------
    public entry fun update_auction_settings(account: &signer, new_duration: u64) acquires AuctionSettings, Config {
        only_admin(account);

        let auction_settings = borrow_global_mut<AuctionSettings>(@proxirun);
        auction_settings.auction_duration = new_duration;
    }

    public entry fun deposit(account: &signer, amount: u64 ) acquires UserBalanceTable, Config {
        let config = borrow_global<Config>(@proxirun);
        coin::transfer<aptos_framework::aptos_coin::AptosCoin>(account, config.bank_address, amount);

        let balance_table = borrow_global_mut<UserBalanceTable>(@proxirun);
        let user_entry = smart_table::borrow_mut_with_default(&mut balance_table.user_balances, address_of(account), UserBalanceEntry {
            available: 0,
            locked: 0
        });

        user_entry.available = user_entry.available + amount;
    }

    public entry fun withdraw(account: &signer, amount: u64 ) acquires UserBalanceTable, Config {
        let balance_table = borrow_global_mut<UserBalanceTable>(@proxirun);
        let user_entry = smart_table::borrow_mut_with_default(&mut balance_table.user_balances, address_of(account), UserBalanceEntry {
            available: 0,
            locked: 0
        });
        if (user_entry.available < amount) {
            abort E_INVALID_WITHDRAWAL
        };

        user_entry.available = user_entry.available - amount;

        let config = borrow_global<Config>(@proxirun);
        let bank_signer = create_signer_with_capability(&config.bank_signer);
        coin::transfer<aptos_framework::aptos_coin::AptosCoin>(&bank_signer, address_of(account), amount);
    }

    public entry fun create_work_request(account: &signer, price: u64) acquires UserBalanceTable, AuctionTable, AuctionSettings {
        let balance_table = borrow_global_mut<UserBalanceTable>(@proxirun);
        let user_entry = smart_table::borrow_mut_with_default(&mut balance_table.user_balances, address_of(account), UserBalanceEntry {
            available: 0,
            locked: 0
        });

        if (user_entry.available < price) {
            abort E_INSUFFICIENT_DEPOSIT
        };

        user_entry.available = user_entry.available - price;
        user_entry.locked = user_entry.locked + price;

        let auction_settings = borrow_global<AuctionSettings>(@proxirun);
        let auction_table = borrow_global_mut<AuctionTable>(@proxirun);

        let curr_id = smart_vector::length(&auction_table.auction_entries);
        smart_vector::push_back(&mut auction_table.auction_entries, AuctionEntry {
            work_request: WorkRequest {
                requester: address_of(account),
                submission_time: timestamp::now_microseconds(),
                max_price: price
            },
            bids: vector::empty<Bid>(),
            winner: option::none<Bid>(),
            status: S_AUCTION_RUNNING
        });

        event::emit(
            OnNewWorkRequest {
                request_id: curr_id,
                requester: address_of(account),
                max_price: price,
                time_limit: timestamp::now_microseconds() + auction_settings.auction_duration
            }
        );

    }

    public entry fun bid_work_request(account: &signer, request_id: u64, price: u64) acquires AuctionTable, AuctionSettings {
        let auction_table = borrow_global_mut<AuctionTable>(@proxirun);

        // check if the work request exists and is still active
        // borrow aborts if the key is not found, or price is above max_price for the request
        let auction_settings = borrow_global<AuctionSettings>(@proxirun);
        let auction_entry = smart_vector::borrow_mut(&mut auction_table.auction_entries, request_id);
        if (timestamp::now_microseconds() > auction_entry.work_request.submission_time + auction_settings.auction_duration) {
            abort E_AUCTION_HAS_ENDED
        };
        if (price > auction_entry.work_request.max_price) {
            abort E_BID_TOO_EXPENSIVE
        };

        vector::push_back(&mut auction_entry.bids, Bid { bidder: signer::address_of(account), price: price });
        event::emit(
            OnNewWorkRequestBid {
                request_id: request_id,
                bidder: signer::address_of(account),
                price: price
            }
        );
    }

    /// Entrypoint to validate that the worker has submitted the required work
    public entry fun commit(account: &signer, request_id: u64) acquires Config, AuctionTable, UserBalanceTable {
        only_admin(account);

        let auction_table = borrow_global_mut<AuctionTable>(@proxirun);
        let auction_entry = smart_vector::borrow_mut(&mut auction_table.auction_entries, request_id);

        if (auction_entry.status != S_WAIT_COMMIT) {
            abort E_COMMIT_INVALID_STATUS
        };

        auction_entry.status = S_RECEIVED_COMMIT;

        // pay provider and refund user for price delta
        let balances = borrow_global_mut<UserBalanceTable>(@proxirun);
        let user_entry = smart_table::borrow_mut(&mut balances.user_balances, auction_entry.work_request.requester);
        let worker_bid = option::borrow (&mut auction_entry.winner);

        user_entry.available = user_entry.available + auction_entry.work_request.max_price - worker_bid.price;
        user_entry.locked = user_entry.locked - auction_entry.work_request.max_price;

        let worker_entry = smart_table::borrow_mut_with_default(&mut balances.user_balances,  worker_bid.bidder, UserBalanceEntry {
            available: 0,
            locked: 0
        });


        worker_entry.available = worker_entry.available + worker_bid.price;

        event::emit(
            OnWorkRequestCompleted {
                request_id: request_id
            }
        );
    }

    /// Entrypoint called once an auction has reached its termination time
    public entry fun finalize_auction(account: &signer, request_id: u64) acquires /*Config,*/ AuctionSettings, AuctionTable, UserBalanceTable {
        //only_admin(account);

        let auction_table = borrow_global_mut<AuctionTable>(@proxirun);
        let auction_entry = smart_vector::borrow_mut(&mut auction_table.auction_entries, request_id);

        // check valid status
        if (auction_entry.status != S_AUCTION_RUNNING) {
            abort E_AUCTION_ALREADY_FINALIZED
        };

        // check time limit
        let auction_settings = borrow_global<AuctionSettings>(@proxirun);
        if (auction_entry.work_request.submission_time + auction_settings.auction_duration > timestamp::now_microseconds()) {
            abort E_AUCTION_NOT_ENDED
        };

        // process the results of the auction
        if (vector::length(&auction_entry.bids) == 0) {
            // auction unsuccessful unlock funds
            let balances = borrow_global_mut<UserBalanceTable>(@proxirun);
            let user_entry = smart_table::borrow_mut(&mut balances.user_balances, auction_entry.work_request.requester);
            user_entry.available = user_entry.available + auction_entry.work_request.max_price;
            user_entry.locked = user_entry.locked - auction_entry.work_request.max_price;

            // mark it has unsuccessful
            auction_entry.status = S_AUCTION_NO_WINNER;

            // notify nobody won auction
            event::emit(
                OnAuctionFailure {
                    request_id
                }
            );
        } else {
            // auction successful, find the cheapest bidder
            let winning_bid = vector::borrow(&auction_entry.bids, 0);
            let curr_id = 1;
            while (curr_id < vector::length(&auction_entry.bids)) {
                if (vector::borrow(&auction_entry.bids, curr_id).price < winning_bid.price) {
                    winning_bid = vector::borrow(&auction_entry.bids, curr_id);
                };

                curr_id = curr_id + 1;
            };

            // store winner and update status
            auction_entry.winner = option::some(*winning_bid);
            auction_entry.status = S_WAIT_COMMIT;

            // emit the event
            event::emit(
                OnBidWon {
                    request_id: request_id,
                    winner: winning_bid.bidder,
                    bid_price: winning_bid.price
                }
            );
        };
    }


    // ---------------- VIEWS ----------------
    #[view]
    public fun get_work_request(request_id: u64): WorkRequest acquires AuctionTable {
        let auction_table = borrow_global<AuctionTable>(@proxirun);
        let auction_entry = smart_vector::borrow(&auction_table.auction_entries, request_id);

        auction_entry.work_request
    }

    #[view]
    public fun get_user_balance(user: address): UserBalanceEntry acquires UserBalanceTable {
        let balances = borrow_global<UserBalanceTable>(@proxirun);
        let user_balance = smart_table::borrow_with_default(
            &balances.user_balances,
            user,
            &UserBalanceEntry {
                available: 0,
                locked: 0
            }
        );

        *user_balance
    }

    #[view]
    public fun get_bids(request_id: u64): vector<Bid> acquires AuctionTable {
        let auction_table = borrow_global<AuctionTable>(@proxirun);
        smart_vector::borrow(&auction_table.auction_entries, request_id).bids
    }

    #[view]
    public fun get_auction(request_id: u64): AuctionEntry acquires AuctionTable {
        let auction_table = borrow_global<AuctionTable>(@proxirun);
        *smart_vector::borrow(&auction_table.auction_entries, request_id)
    }

    #[view]
    public fun get_batch_auction(request_ids: vector<u64>): vector<AuctionEntry> acquires AuctionTable {
        let accumulator = vector::empty<AuctionEntry>();
        let auction_table = borrow_global<AuctionTable>(@proxirun);

        for (i in 0..vector::length(&request_ids)) {
            let request_id = vector::borrow(&request_ids, i);
            vector::push_back(&mut accumulator, *smart_vector::borrow(&auction_table.auction_entries, *request_id));
        };

        accumulator
    }

    #[view]
    public fun get_auction_settings(): AuctionSettings acquires AuctionSettings {
        *borrow_global<AuctionSettings>(@proxirun)
    }

    #[view]
    public fun get_counter(): u64 acquires AuctionTable {
        let auction_table = borrow_global<AuctionTable>(@proxirun);
        smart_vector::length(&auction_table.auction_entries)
    }

    // ---------------- TESTS ----------------
    #[test_only]
    use aptos_framework::coin::CoinStore;
    #[test_only]
    use std::string::{String,utf8};
    #[test_only]
    use aptos_framework::account;


    /*
    #[test(admin = @ml_auction2, user=@0xBABE, aptos_addr=@0x1, processor=@0xBABA)] // OK
    fun test_deposit(admin: signer, user: signer, aptos_addr: signer, processor: signer) acquires UserBalances, Config, ContractData, AuctionSettings, AuctionResultTracker {
        account::create_account_for_test(address_of(&user));
        account::create_account_for_test(address_of(&processor));
        timestamp::set_time_has_started_for_testing(&aptos_addr);

        let (a, b, mint_cap) = coin::initialize<AptosCoin>(&aptos_addr,  utf8(b"YEP"), utf8(b"YEP"), 8, false );
        let coins = coin::mint<AptosCoin>(4200, &mint_cap);

        coin::register<AptosCoin>(&user);

        coin::destroy_burn_cap(a);
        coin::destroy_freeze_cap(b);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit(address_of(&user), coins);

        init_module(&admin);
        deposit(&user, 64);
        withdraw(&user, 32);

        create_work_request(&user, 32);
        bid_work_request(&processor, 0, 16);

        timestamp::fast_forward_seconds(100);

        finalize_auction(&admin, 0);
        commit(&admin, 0);
    }
    */
}



