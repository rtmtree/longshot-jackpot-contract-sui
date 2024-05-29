module rtmtree::longshot_jackpot {
    //==============================================================================================
    // Dependencies
    //==============================================================================================
    // use sui::coin;
    use sui::coin::{Self, Coin};
    use sui::event;
    use std::vector;
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context;
    use sui::url::{Self, Url};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;
    use std::string::{Self, String};
    use sui::balance::{Self, Balance};
    use sui::vec_map::{Self, VecMap};

    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use sui::test_utils::assert_eq;

    //==============================================================================================
    // Constants - Add your constants here (if any)
    //==============================================================================================

    const SHOOT_DURATION : u64 = 90 * 1000; // 90 seconds

    //==============================================================================================
    // Error codes - DO NOT MODIFY
    //==============================================================================================

    const ESIGNER_NOT_ADMIN: u64 = 0;
    const EPLAYER_HAS_NOT_JOINED: u64 = 1;
    const EDEADLINE_HAS_PASSED: u64 = 2;
    const EDEADLINE_HAS_NOT_PASSED: u64 = 3;
    const EINSUFFICIENT_BALANCE: u64 = 4;

    //==============================================================================================
    // Module Structs - DO NOT MODIFY
    //==============================================================================================

    struct GameState has key, store {
        id: UID,
        // game_owner_cap : ID,
        shoot_deadline_mapper: VecMap<address, u64>,
        // ticket price
        ticket_price: u64,
        // reward percentage
        reward_percentage: u64,
        // game_admin percentage
        admin_percentage: u64,
        // reward_resource_pool: Coin<SUI>,
        reward_resource_pool: Balance<SUI>,
        game_admin: address
    }
    // struct GameOwnerCapability has key {
    //     id: UID,
    //     game: ID,
    // }

    //==============================================================================================
    // Event structs - DO NOT MODIFY
    //==============================================================================================

    struct ShootEvent has copy, drop {
        player: address,
        shoot_deadline: u64,
        timestamp: u64
    }
    struct GoalShotEvent has copy, drop {
        player: address,
        reward: u64,
        timestamp: u64
    }
    struct TicketPriceUpdateEvent has copy, drop {
        old_ticket_price: u64,
        new_ticket_price: u64,
        timestamp: u64
    }
    struct GameCreated has copy, drop {
        game_id: ID,
        // game_owner_cap_id: ID,
        game_admin: address
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    public entry fun create_game(
        game_admin: address, 
        ctx: &mut TxContext
        ) {

        let id = object::new(ctx);
        let game_id = object::uid_to_inner(&id);

        let game_object = GameState {
            id: id,
            ticket_price: 10000000, // 0.01 SUI
            reward_percentage: 80,
            admin_percentage: 4,
            reward_resource_pool: balance::zero(),
            shoot_deadline_mapper: vec_map::empty(),
            game_admin: game_admin
        };

        transfer::public_share_object(game_object);
        
        event::emit(
            GameCreated {
                game_id : game_id,
                game_admin: game_admin
            }
        );

    }

    public entry fun shoot(
        game : &mut GameState,
        payment: Coin<SUI>,
        clock: &Clock,
        player_address: address
    ) {

        // === Uncomment this to let user wait til the deadline pass before reshoot ===
        // // Check if the player is already joined
        // if (vec_map::contains_key(&state.shoot_deadline_mapper, &signer::address_of(player))){
        //     // Assert that the last shoot deadline is passed
        //     assert!( *vec_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(player)) < timestamp::now_seconds(), EDEADLINE_HAS_NOT_PASSED);
        // };
        // ============================================================================

        // Transfer ticket price to the resource account
        {
            let ticket_price = game.ticket_price;
            assert!(
                coin::value(&payment) >= ticket_price, 
                EINSUFFICIENT_BALANCE
            );
            let payment_balance = coin::into_balance(payment);
            balance::join(&mut game.reward_resource_pool, payment_balance);
        };

        // Set the shoot deadline for this player
        let shoot_deadline = clock::timestamp_ms(clock) + SHOOT_DURATION;
        if (vec_map::contains(&game.shoot_deadline_mapper, &player_address)){
            vec_map::remove(&mut game.shoot_deadline_mapper, &player_address);
        };
        vec_map::insert(&mut game.shoot_deadline_mapper, player_address, shoot_deadline);

        // Emit ShootEvent event
        event::emit(
            ShootEvent {
                player: player_address,
                shoot_deadline: shoot_deadline,
                timestamp: clock::timestamp_ms(clock) 
            }
        );
    }

    public fun goal_shot(
        game : &mut GameState,
        clock: &Clock,
        player: address,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert_sender_is_admin(game, ctx);

        let reward_coin = coin::zero(ctx);

        // Assert that player joined the game
        assert!(vec_map::contains(&game.shoot_deadline_mapper, &player), EPLAYER_HAS_NOT_JOINED);

        // Assert that the shoot deadline is not passed
        assert!(*vec_map::get(&game.shoot_deadline_mapper, &player) > clock::timestamp_ms(clock) , EDEADLINE_HAS_PASSED);

        // Get how much reward the player should get
        let pool = balance::value<SUI>(&game.reward_resource_pool);
        let player_reward = pool * game.reward_percentage / 100;
        let admin_reward = pool * game.admin_percentage / 100;

        // Transfer reward to the admin
        if (admin_reward > 0){
            // let resource_signer = &account::create_signer_with_capability(&state.sign_cap);
            // coin::transfer<AptosCoin>(resource_signer, @admin, admin_reward);
        };

        // Transfer reward to the player
        let split_balance = balance::split(&mut game.reward_resource_pool, player_reward);
        let split_coin = coin::from_balance(split_balance, ctx);
        coin::join(&mut reward_coin, split_coin);

        event::emit(
            GoalShotEvent {
                player: player,
                reward: move player_reward,
                timestamp: clock::timestamp_ms(clock) 
            }
        );

        reward_coin
    }

    public entry fun set_ticket_price(
        game : &mut GameState,
        ticket_price: u64,
        clock: &Clock,
        ctx: &mut TxContext

    ) {
        assert_sender_is_admin(game, ctx);

        let old_ticket_price = game.ticket_price;
        game.ticket_price = ticket_price;
        
        event::emit(
            TicketPriceUpdateEvent {
                old_ticket_price,
                new_ticket_price: move ticket_price,
                timestamp: clock::timestamp_ms(clock)
            }
        );
    }

    public entry fun set_reward_percentage(
        game : &mut GameState,
        reward_percentage: u64,
        ctx: &mut TxContext
    ) {
        assert_sender_is_admin(game, ctx);

        game.reward_percentage = move reward_percentage;
    }

    public entry fun set_admin_percentage(
        game : &mut GameState,
        admin_percentage: u64,
        ctx: &mut TxContext
    ) {
        assert_sender_is_admin(game, ctx);

        game.admin_percentage = move admin_percentage;
    }

    public fun emergency_withdraw(
        game : &mut GameState,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert_sender_is_admin(game, ctx);

        let withdraw_coin = coin::zero(ctx);
        let resource_value = balance::value(&game.reward_resource_pool);
        let balance = balance::split(&mut game.reward_resource_pool, resource_value);
        let coin = coin::from_balance(balance, ctx);

        coin::join(&mut withdraw_coin, coin);

        withdraw_coin
    }

    /////////////
    // VIEWS ////
    /////////////

    #[ext(view)]
    /*
        Return the ticket price
        @return - the ticket price
    */
    public fun get_ticket_price(
        game : &GameState
    ): u64  {
        game.ticket_price
    }

    #[ext(view)]
    /*
        Return the reward percentage
        @return - the reward percentage
    */
    public fun get_reward_percentage(
        game : &GameState
    ): u64  {
        game.reward_percentage
    }

    #[ext(view)]
    /*
        Return the admin percentage
        @return - the admin percentage
    */
    public fun get_admin_percentage(
        game : &GameState
    ): u64  {
        game.admin_percentage
    }

    #[ext(view)]
    /*
        Return the shoot deadline for the player
        @param player - the player address
        @return - the shoot deadline for the player
    */
    public fun get_shoot_deadline(
        game : &GameState,
        player: address,
    ): u64  {
        *vec_map::get(&game.shoot_deadline_mapper, &player)
    }

    #[ext(view)]
    /*
        Return the shoot duration
        @return - the shoot duration
    */
    public fun get_shoot_duration(): u64 {
        SHOOT_DURATION
    }

    //==============================================================================================
    // Helper functions - Add your helper functions here (if any)
    //==============================================================================================

    //==============================================================================================
    // Validation functions - Add your validation functions here (if any)
    //==============================================================================================

    fun assert_sender_is_admin( game: &GameState ,ctx: &TxContext) {
        assert!(tx_context::sender(ctx) == game.game_admin, ESIGNER_NOT_ADMIN);
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================
    
    #[test]
    fun test_create_game_success() {

        let game_creator = @0xa;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);
            

            assert!(game.ticket_price == 10000000, 0);
            assert!(game.reward_percentage == 80, 0);
            assert!(game.admin_percentage == 4, 0);

            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 10000000, 0);

            let reward_percentage = get_reward_percentage(&game);
            assert!(reward_percentage == 80, 0);

            let admin_percentage = get_admin_percentage(&game);
            assert!(admin_percentage == 4, 0);

            let game_admin = game.game_admin;
            assert!(game_admin == game_creator, 0);

            test_scenario::return_shared(game);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_set_ticket_price_success() {
        
        let game_creator = @0xa;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);
            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_ticket_price(&mut game, 100, &clock, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 100, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 100, 0);
            
            set_ticket_price(&mut game, 20, &clock, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);
            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 20, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 20, 0);


            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_set_reward_percentage_success() {
        let game_creator = @0xa;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_reward_percentage(&mut game, 90, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                0
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.reward_percentage == 90, 0);
            let reward_percentage = get_reward_percentage(&game);
            assert!(reward_percentage == 90, 0);
            
            set_reward_percentage(&mut game, 70, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                0
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.reward_percentage == 70, 0);
            let reward_percentage = get_reward_percentage(&game);
            assert!(reward_percentage == 70, 0);


            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_set_admin_percentage_success() {
        let game_creator = @0xa;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_admin_percentage(&mut game, 10, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                0
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.admin_percentage == 10, 0);
            let admin_percentage = get_admin_percentage(&game);
            assert!(admin_percentage == 10, 0);
            
            set_admin_percentage(&mut game, 20, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                0
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.admin_percentage == 20, 0);
            let admin_percentage = get_admin_percentage(&game);
            assert!(admin_percentage == 20, 0);


            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);
        };

        test_scenario::end(scenario_val);
    }

     #[test]
    fun test_shoot_for_free_twice_success() {
        let game_creator = @0xa;
        let player = @0xb;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_ticket_price(&mut game, 0, &clock, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 0, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 0, 0);
            
            shoot(&mut game, coin::zero(test_scenario::ctx(scenario)), &clock, player);
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            let shoot_deadline = get_shoot_deadline(&game, player);
            assert!(shoot_deadline == clock::timestamp_ms(&clock) + SHOOT_DURATION, 0);

            clock::increment_for_testing(&mut clock, SHOOT_DURATION + 1);

            shoot(&mut game, coin::zero(test_scenario::ctx(scenario)), &clock, player);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            shoot(&mut game, coin::zero(test_scenario::ctx(scenario)), &clock, player);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            let shoot_deadline = get_shoot_deadline(&game, player);
            assert!(shoot_deadline == clock::timestamp_ms(&clock) + SHOOT_DURATION, 0);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

        };

        test_scenario::end(scenario_val);
    }


    #[test]
    fun test_shoot_1_sui_twice_success() {
        let game_creator = @0xa;
        let player = @0xb;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_ticket_price(&mut game, 1, &clock, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 1, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 1, 0);

            let payment_coin = coin::mint_for_testing<SUI>(1, test_scenario::ctx(scenario));
            
            shoot(&mut game, payment_coin, &clock, player);
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );


            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            let shoot_deadline = get_shoot_deadline(&game, player);
            assert!(shoot_deadline == clock::timestamp_ms(&clock) + SHOOT_DURATION, 0);

            clock::increment_for_testing(&mut clock, SHOOT_DURATION + 1);

            let payment_coin = coin::mint_for_testing<SUI>(1, test_scenario::ctx(scenario));
            shoot(&mut game, payment_coin, &clock, player);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );
        };
        test_scenario::end(scenario_val);
    }


    #[test]
    #[expected_failure(abort_code = EINSUFFICIENT_BALANCE)]
    fun test_shoot_2_sui_failure_sui_not_enough(){

        let game_creator = @0xa;
        let player = @0xb;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {

            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_ticket_price(&mut game, 2, &clock, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 2, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 2, 0);

            let payment_coin = coin::mint_for_testing<SUI>(1, test_scenario::ctx(scenario));
            
            shoot(&mut game, payment_coin, &clock, player);
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_shoot_1_sui_twice_and_goal_shot_success() {

        let game_creator = @0xa;
        let player = @0xb;

        let scenario_val = test_scenario::begin(game_creator);
        let scenario = &mut scenario_val;
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, game_creator);

        {
            let clock = test_scenario::take_shared<Clock>(scenario);
            create_game(game_creator, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
        };
        let tx = test_scenario::next_tx(scenario, game_creator);
        let expected_events_emitted = 1;
        let expected_created_objects = 1;
        assert_eq(
            test_scenario::num_user_events(&tx), 
            expected_events_emitted
        );
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        
        {
            let game: GameState = test_scenario::take_shared<GameState>(scenario);

            let clock = test_scenario::take_shared<Clock>(scenario);
            
            set_ticket_price(&mut game, 1, &clock, test_scenario::ctx(scenario));

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, player);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);

            assert!(game.ticket_price == 1, 0);
            let ticket_price = get_ticket_price(&game);
            assert!(ticket_price == 1, 0);

            let payment_coin = coin::mint_for_testing<SUI>(1, test_scenario::ctx(scenario));
            
            shoot(&mut game, payment_coin, &clock, player);
            
            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );

            let game: GameState = test_scenario::take_shared<GameState>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);

            
            let claim_coin = goal_shot(&mut game, &clock, player, test_scenario::ctx(scenario));

            let pool = balance::value<SUI>(&game.reward_resource_pool);
            assert_eq(
                coin::value(&claim_coin), 
                pool * game.reward_percentage / 100
            );
            coin::burn_for_testing(claim_coin);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(game);

            let tx = test_scenario::next_tx(scenario, game_creator);
            assert_eq(
                test_scenario::num_user_events(&tx), 
                1
            );
        };

        test_scenario::end(scenario_val);
    }
}
