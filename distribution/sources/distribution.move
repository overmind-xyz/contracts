/// this module provides the foundation for Overmind's prize distribution
module overmind::distribution {
    use std::error;
    use std::signer;
    use std::string::{String, bytes};
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::coin::{Self};
    use aptos_framework::managed_coin;
    use aptos_framework::timestamp;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};

    //
    // Errors
    //
    /// distribution store exists
    const ERROR_DISTRIBUTION_STORE_EXISTS: u64 = 0;

    /// distribution store does not exist
    const ERROR_DISTRIBUTION_STORE_DOES_NOT_EXIST: u64 = 1;

    /// distribution id exists
    const ERROR_DISTRIBUTION_ID_EXISTS: u64 = 2;

    /// distribution id does not exist
    const ERROR_DISTRIBUTION_ID_DOES_NOT_EXISTS: u64 = 3;

    /// no prize addresses were provided
    const ERROR_NO_PRIZE_ADDRESSES: u64 = 4;

    /// lenghts of prize_addresses and prize_amounts not equal
    const ERROR_PRIZE_LENGTHS_NOT_EQUAL: u64 = 5;

    /// expiration time is less than current time
    const ERROR_INVALID_EXPIRATION: u64 = 6;

    /// prize not found
    const ERROR_PRIZE_NOT_FOUND: u64 = 7;

    /// has expired
    const ERROR_HAS_EXPIRED: u64 = 8;

    //
    // Core data structures
    //
    /// represents a distribution of prizes
    struct Distribution<phantom CoinType> has key, store, drop {
        /// escrow account to hold the distribution's coins
        escrow_signer: account::SignerCapability,
        /// map of claimable prizes
        prizes: SimpleMap<address, u64>,
        /// claim prize expiration in seconds
        expiration_seconds: u64,
    }

    /// set of data sent to event stream when adding a new distribution
    struct AddDistributionEvent<phantom CoinType> has drop, store {
        distribution_id: String,
        escrow_address: address,
        prize_addresses: vector<address>,
        prize_amounts: vector<u64>,
        expiration_seconds: u64,
    }

    /// set of data sent to event stream when removing a distribution
    struct RemoveDistributionEvent has drop, store {
        distribution_id: String,
    }

    /// set of data sent to event stream when adding a new prize for a specific distribution_id
    struct AddPrizeEvent has drop, store {
        distribution_id: String,
        address: address,
        amount: u64,
    }

    /// set of data sent to event stream when removing a prize for a specific distribution_id
    struct RemovePrizeEvent has drop, store {
        distribution_id: String,
        address: address,
    }

    /// set of data sent to event stream when updating a prize's expiration for a specific distribution_id
    struct UpdatePrizeExpirationEvent has drop, store {
        distribution_id: String,
        expiration_seconds: u64
    }

    /// set of data sent to event stream when claiming a prize for a specific distribution_id
    struct ClaimPrizeEvent has drop, store {
        distribution_id: String,
        address: address,
    }

    /// represents all distribution data of a creator
    struct DistributionStore<phantom CoinType> has key {
        /// table of distributions with universally unique identifiers as keys
        distributions: Table<String, Distribution<CoinType>>,
        /// address in which all funds go back to if not the claimee
        refund_address: address,
        add_distribution_event: EventHandle<AddDistributionEvent<CoinType>>,
        remove_distribution_event: EventHandle<RemoveDistributionEvent>,
        add_prize_event: EventHandle<AddPrizeEvent>,
        remove_prize_event: EventHandle<RemovePrizeEvent>,
        update_prize_expiration_event: EventHandle<UpdatePrizeExpirationEvent>,
        claim_prize_event: EventHandle<ClaimPrizeEvent>,
    }

    //
    // Entry functions
    //
    /// initialize distribution
    public entry fun initialize_distribution<CoinType>(
        account: &signer,
        refund_address: address,
    ) {
        let account_address = signer::address_of(account);

        // check to make sure distribution store does not exist
        assert!(
            !exists<DistributionStore<CoinType>>(account_address),
            error::invalid_state(ERROR_DISTRIBUTION_STORE_EXISTS)
        );

        move_to(account, DistributionStore<CoinType> {
            distributions: table::new(),
            refund_address,
            add_distribution_event: account::new_event_handle<AddDistributionEvent<CoinType>>(account),
            remove_distribution_event: account::new_event_handle<RemoveDistributionEvent>(account),
            add_prize_event: account::new_event_handle<AddPrizeEvent>(account),
            remove_prize_event: account::new_event_handle<RemovePrizeEvent>(account),
            update_prize_expiration_event: account::new_event_handle<UpdatePrizeExpirationEvent>(account),
            claim_prize_event: account::new_event_handle<ClaimPrizeEvent>(account),
        });
    }

    /// add distribution to a specific distribution_id
    public entry fun add_distribution<CoinType>(
        account: &signer,
        distribution_id: String,
        prize_addresses: vector<address>,
        prize_amounts: vector<u64>,
        expiration_seconds: u64
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(account_address);
        assert_distribution_id_does_not_exist<CoinType>(account_address, distribution_id);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(account_address);

        // check if there are any prize addresses
        assert!(vector::length(&prize_addresses) != 0, error::invalid_argument(ERROR_NO_PRIZE_ADDRESSES));

        // check if lengths of prize_addresses and prize_amounts are equal
        assert!(
            vector::length(&prize_addresses) == vector::length(&prize_amounts),
            error::invalid_argument(ERROR_PRIZE_LENGTHS_NOT_EQUAL)
        );

        // check to make sure expiration is greater then current time
        assert!(timestamp::now_seconds() < expiration_seconds, error::invalid_state(ERROR_INVALID_EXPIRATION));

        let (escrow_signer, escrow_signer_cap) = account::create_resource_account(account, *bytes(&distribution_id));
        managed_coin::register<CoinType>(&escrow_signer);

        let prizes: SimpleMap<address, u64> = simple_map::create();
        let total_amount: u64 = 0;

        let i = 0;
        while (i < vector::length(&prize_addresses)) {
            let address = *vector::borrow(&prize_addresses, i);
            let amount = *vector::borrow(&prize_amounts, i);

            let new_amount = amount;

            if (simple_map::contains_key(&mut prizes, &address)) {
                let (_, amount) = simple_map::remove(&mut prizes, &address);
                new_amount = new_amount + amount;
            };

            simple_map::add(&mut prizes, address, new_amount);

            total_amount = total_amount + amount;
            i = i + 1;
        };

        coin::transfer<CoinType>(account, signer::address_of(&escrow_signer), total_amount);

        table::add(&mut distribution_store.distributions, distribution_id, Distribution<CoinType> {
            prizes,
            expiration_seconds,
            escrow_signer: escrow_signer_cap
        });

        event::emit_event<AddDistributionEvent<CoinType>>(
            &mut distribution_store.add_distribution_event,
            AddDistributionEvent<CoinType> {
                distribution_id,
                escrow_address: signer::address_of(&escrow_signer),
                prize_addresses,
                prize_amounts,
                expiration_seconds,
            },
        );
    }

    /// remove an entire distribution
    public entry fun remove_distribution<CoinType>(
        account: &signer,
        distribution_id: String,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(account_address);
        assert_distribution_id_exists<CoinType>(account_address, distribution_id);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(account_address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        coin::transfer<CoinType>(
            &account::create_signer_with_capability(&distribution.escrow_signer),
            distribution_store.refund_address,
            coin::balance<CoinType>(account::get_signer_capability_address(&distribution.escrow_signer))
        );

        table::remove(&mut distribution_store.distributions, distribution_id);

        event::emit_event<RemoveDistributionEvent>(
            &mut distribution_store.remove_distribution_event,
            RemoveDistributionEvent {
                distribution_id,
            },
        );
    }

    /// add a prize to a specific distribution_id
    public entry fun add_prize<CoinType>(
        account: &signer,
        distribution_id: String,
        address: address,
        amount: u64,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(account_address);
        assert_distribution_id_exists<CoinType>(account_address, distribution_id);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(account_address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        let new_amount = amount;

        if (simple_map::contains_key(&mut distribution.prizes, &address)) {
            let (_, amount) = simple_map::remove(&mut distribution.prizes, &address);
            new_amount = new_amount + amount;
        };
        simple_map::add(&mut distribution.prizes, address, new_amount);

        coin::transfer<CoinType>(account, account::get_signer_capability_address(&distribution.escrow_signer), amount);

        event::emit_event<AddPrizeEvent>(
            &mut distribution_store.add_prize_event,
            AddPrizeEvent {
                distribution_id,
                address,
                amount,
            },
        );
    }

    /// remove a prize from a specific distribution_id
    public entry fun remove_prize<CoinType>(
        account: &signer,
        distribution_id: String,
        address: address,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(account_address);
        assert_distribution_id_exists<CoinType>(account_address, distribution_id);
        assert_distribution_id_prize_exists<CoinType>(account_address, distribution_id, address);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(account_address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        let (_, amount) = simple_map::remove(&mut distribution.prizes, &address);

        coin::transfer<CoinType>(
            &account::create_signer_with_capability(&distribution.escrow_signer),
            distribution_store.refund_address,
            amount
        );

        event::emit_event<RemovePrizeEvent>(
            &mut distribution_store.remove_prize_event,
            RemovePrizeEvent {
                distribution_id,
                address,
            },
        );
    }

    /// update a prize expiration for a specific distribution_id
    public entry fun update_prize_expiration<CoinType>(
        account: &signer,
        distribution_id: String,
        expiration_seconds: u64
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(account_address);
        assert_distribution_id_exists<CoinType>(account_address, distribution_id);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(account_address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        distribution.expiration_seconds = expiration_seconds;

        event::emit_event<UpdatePrizeExpirationEvent>(
            &mut distribution_store.update_prize_expiration_event,
            UpdatePrizeExpirationEvent {
                distribution_id,
                expiration_seconds,
            },
        );
    }

    /// claim a prize for a specific distribution_id
    public entry fun claim_prize<CoinType>(
        account: &signer,
        distribution_address: address,
        distribution_id: String,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        assert_distribution_store_exists<CoinType>(distribution_address);
        assert_distribution_id_exists<CoinType>(distribution_address, distribution_id);
        assert_distribution_id_prize_exists<CoinType>(distribution_address, distribution_id, account_address);

        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(distribution_address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        // check to make sure distribution has not expired
        assert!(timestamp::now_seconds() < distribution.expiration_seconds, error::invalid_state(ERROR_HAS_EXPIRED));

        if (!coin::is_account_registered<CoinType>(account_address)) {
            coin::register<CoinType>(account);
        };

        let (_, amount) = simple_map::remove(&mut distribution.prizes, &account_address);

        coin::transfer<CoinType>(
            &account::create_signer_with_capability(&distribution.escrow_signer),
            account_address,
            amount
        );

        event::emit_event<RemovePrizeEvent>(
            &mut distribution_store.remove_prize_event,
            RemovePrizeEvent {
                distribution_id,
                address: account_address,
            },
        );
    }

    //
    // Private functions
    //
    fun assert_distribution_store_exists<CoinType>(
        address: address,
    ) {
        // check to make sure distribution store exists
        assert!(
            exists<DistributionStore<CoinType>>(address),
            error::invalid_state(ERROR_DISTRIBUTION_STORE_DOES_NOT_EXIST)
        );
    }

    fun assert_distribution_id_exists<CoinType>(
        address: address,
        distribution_id: String,
    ) acquires DistributionStore {
        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(address);

        // check to make sure distribution_id exists
        assert!(
            table::contains(&mut distribution_store.distributions, distribution_id),
            error::invalid_state(ERROR_DISTRIBUTION_ID_DOES_NOT_EXISTS)
        );
    }

    fun assert_distribution_id_does_not_exist<CoinType>(
        address: address,
        distribution_id: String,
    ) acquires DistributionStore {
        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(address);

        // check to make sure distribution_id does not exist
        assert!(
            !table::contains(&mut distribution_store.distributions, distribution_id),
            error::invalid_state(ERROR_DISTRIBUTION_ID_EXISTS)
        );
    }

    fun assert_distribution_id_prize_exists<CoinType>(
        address: address,
        distribution_id: String,
        prize_address: address,
    ) acquires DistributionStore {
        let distribution_store = borrow_global_mut<DistributionStore<CoinType>>(address);
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        // check to make sure prize exists
        assert!(
            simple_map::contains_key(&mut distribution.prizes, &prize_address),
            error::invalid_argument(ERROR_PRIZE_NOT_FOUND)
        );
    }

    //
    // Test functions
    //
    #[test_only]
    use std::string;

    #[test(account = @0xCAFE)]
    fun test_assert_distribution_store_exists_success(account: &signer) {
        let account_address = signer::address_of(account);

        account::create_account_for_test(account_address);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        assert_distribution_store_exists<coin::FakeMoney>(account_address);
    }

    #[test(account = @0xCAFE)]
    #[expected_failure(abort_code = 196609)]
    fun test_assert_distribution_store_exists_failure(account: &signer) {
        let account_address = signer::address_of(account);

        account::create_account_for_test(account_address);

        assert_distribution_store_exists<coin::FakeMoney>(account_address);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    fun test_assert_distribution_id_exists_success(
        aptos_framework: &signer,
        account: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(account_address);

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, account_address, 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_exists<coin::FakeMoney>(account_address, distribution_id);
    }

    #[test(account = @0xCAFE)]
    #[expected_failure(abort_code = 196611)]
    fun test_assert_distribution_id_exists_failure(
        account: &signer,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        account::create_account_for_test(account_address);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");

        assert_distribution_id_exists<coin::FakeMoney>(account_address, distribution_id);
    }

    #[test(account = @0xCAFE)]
    fun test_assert_distribution_id_does_not_exist_success(
        account: &signer,
    ) acquires DistributionStore {
        let account_address = signer::address_of(account);

        account::create_account_for_test(account_address);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");

        assert_distribution_id_does_not_exist<coin::FakeMoney>(account_address, distribution_id);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    #[expected_failure(abort_code = 196610)]
    fun test_assert_distribution_id_does_not_exist_failure(
        aptos_framework: &signer,
        account: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(account_address);

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, account_address, 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_does_not_exist<coin::FakeMoney>(account_address, distribution_id);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    fun test_assert_distribution_id_prize_exists_success(
        aptos_framework: &signer,
        account: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(account_address);

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, account_address, 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_prize_exists<coin::FakeMoney>(
            account_address,
            distribution_id,
            signer::address_of(test1),
        );
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
    )]
    #[expected_failure(abort_code = 25863)]
    fun test_assert_distribution_id_prize_exists_failure(
        aptos_framework: &signer,
        account: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(account_address);

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, account_address, 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            account_address
        );

        let distribution_id = string::utf8(b"test-id");

        assert_distribution_id_prize_exists<coin::FakeMoney>(
            account_address,
            distribution_id,
            signer::address_of(account),
        );
    }

    #[test(aptos_framework = @0x1, account = @0xCAFE, refund_address = @0x123)]
    fun test_initialize_distribution_success(aptos_framework: &signer, account: &signer, refund_address: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        assert_distribution_store_exists<coin::FakeMoney>(signer::address_of(account));
    }

    #[test(aptos_framework = @0x1, account = @0xCAFE, refund_address = @0x123)]
    #[expected_failure(abort_code = 196608)]
    fun test_initialize_distribution_failure(
        aptos_framework: &signer,
        account: &signer,
        refund_address: &signer
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refund_address = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    fun test_add_distribution_success(
        aptos_framework: &signer,
        account: &signer,
        refund_address: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_exists<coin::FakeMoney>(signer::address_of(account), distribution_id);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refund_address = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    #[expected_failure(abort_code = 65540)]
    fun test_add_distribution_failure_no_prize_addresses(
        aptos_framework: &signer,
        account: &signer,
        refund_address: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        )
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refund_address = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    #[expected_failure(abort_code = 65541)]
    fun test_add_distribution_failure_addresses_and_amounts_not_equal(
        aptos_framework: &signer,
        account: &signer,
        refund_address: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        )
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refund_address = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    #[expected_failure(abort_code = 196614)]
    fun test_add_distribution_failure_expiration_less_then_or_equal_to_curernt_time(
        aptos_framework: &signer,
        account: &signer,
        refund_address: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refund_address));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refund_address)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds();

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        )
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78
    )]
    fun test_remove_distribution_success(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        coin::register<coin::FakeMoney>(refunder);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_exists<coin::FakeMoney>(signer::address_of(account), distribution_id);

        remove_distribution<coin::FakeMoney>(account, distribution_id);

        assert_distribution_id_does_not_exist<coin::FakeMoney>(signer::address_of(account), distribution_id);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78,
        test4 = @0x89,
    )]
    fun test_add_prize_success(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
        test4: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));
        account::create_account_for_test(signer::address_of(test4));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        coin::register<coin::FakeMoney>(refunder);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_exists<coin::FakeMoney>(signer::address_of(account), distribution_id);

        add_prize<coin::FakeMoney>(account, distribution_id, signer::address_of(test4), 4000000);
        add_prize<coin::FakeMoney>(account, distribution_id, signer::address_of(test4), 4000000);

        assert_distribution_id_prize_exists<coin::FakeMoney>(
            signer::address_of(account),
            distribution_id,
            signer::address_of(test4)
        );

        let distribution_store = borrow_global_mut<DistributionStore<coin::FakeMoney>>(signer::address_of(account));
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        assert!(*simple_map::borrow(&distribution.prizes, &signer::address_of(test4)) == 8000000, 0);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78,
        test4 = @0x89,
    )]
    fun test_remove_prize_success(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
        test4: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));
        account::create_account_for_test(signer::address_of(test4));


        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        coin::register<coin::FakeMoney>(refunder);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        assert_distribution_id_exists<coin::FakeMoney>(signer::address_of(account), distribution_id);

        remove_prize<coin::FakeMoney>(account, distribution_id, signer::address_of(test3));

        let distribution_store = borrow_global_mut<DistributionStore<coin::FakeMoney>>(signer::address_of(account));
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        // check to make sure prize does not exsit
        assert!(
            !simple_map::contains_key(&mut distribution.prizes, &signer::address_of(test3)),
            0
        );

        assert!(coin::balance<coin::FakeMoney>(signer::address_of(refunder)) == 3000000, 1);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78,
    )]
    fun test_update_prize_expiration_success(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        let distribution_store = borrow_global_mut<DistributionStore<coin::FakeMoney>>(signer::address_of(account));
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        assert!(distribution.expiration_seconds == expiration_seconds, 0);

        let updated_expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24 * 7;

        update_prize_expiration<coin::FakeMoney>(account, distribution_id, updated_expiration_seconds);

        let updated_distribution_store = borrow_global_mut<DistributionStore<coin::FakeMoney>>(
            signer::address_of(account)
        );
        let updated_distribution = table::borrow_mut(&mut updated_distribution_store.distributions, distribution_id);

        assert!(updated_distribution.expiration_seconds == updated_expiration_seconds, 1);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78,
    )]
    fun test_claim_prize_success(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        claim_prize<coin::FakeMoney>(test1, signer::address_of(account), distribution_id);

        let distribution_store = borrow_global_mut<DistributionStore<coin::FakeMoney>>(signer::address_of(account));
        let distribution = table::borrow_mut(&mut distribution_store.distributions, distribution_id);

        assert!(
            coin::balance<coin::FakeMoney>(
                account::get_signer_capability_address(&distribution.escrow_signer)
            ) == 5000000,
            0
        );
        assert!(coin::balance<coin::FakeMoney>(signer::address_of(test1)) == 1000000, 1);
    }

    #[test(
        aptos_framework = @0x1,
        account = @0xCAFE,
        refunder = @0x12,
        test1 = @0x34,
        test2 = @0x56,
        test3 = @0x78,
    )]
    #[expected_failure(abort_code = 196616)]
    fun test_claim_prize_failure_has_expired(
        aptos_framework: &signer,
        account: &signer,
        refunder: &signer,
        test1: &signer,
        test2: &signer,
        test3: &signer,
    ) acquires DistributionStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(account));
        account::create_account_for_test(signer::address_of(refunder));

        account::create_account_for_test(signer::address_of(test1));
        account::create_account_for_test(signer::address_of(test2));
        account::create_account_for_test(signer::address_of(test3));

        coin::create_fake_money(aptos_framework, account, 100000000);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(account), 100000000);

        initialize_distribution<coin::FakeMoney>(
            account,
            signer::address_of(refunder)
        );

        let distribution_id = string::utf8(b"test-id");
        let prize_addresses: vector<address> = vector::empty();
        let prize_amounts: vector<u64> = vector::empty();
        let expiration_seconds = timestamp::now_seconds() + 60 * 60 * 24;

        vector::push_back(&mut prize_addresses, signer::address_of(test1));
        vector::push_back(&mut prize_addresses, signer::address_of(test2));
        vector::push_back(&mut prize_addresses, signer::address_of(test3));

        vector::push_back(&mut prize_amounts, 1000000);
        vector::push_back(&mut prize_amounts, 2000000);
        vector::push_back(&mut prize_amounts, 3000000);

        add_distribution<coin::FakeMoney>(
            account,
            distribution_id,
            prize_addresses,
            prize_amounts,
            expiration_seconds
        );

        // set time past expiration_seconds
        timestamp::fast_forward_seconds(60 * 60 * 24 * 7);

        claim_prize<coin::FakeMoney>(test1, signer::address_of(account), distribution_id);
    }
}