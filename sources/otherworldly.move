module otherworldly::character_collection {
use std::string::String;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::balance::{Self, Balance};
use sui::event;
use sui::table::{Self, Table};
use sui::clock::{Self, Clock};
use sui::url::{Self, Url};
use sui::vec_map::{Self, VecMap};

// ==================== Error Codes ====================
const E_NOT_AUTHORIZED: u64 = 0;
const E_INVALID_ACCESSORY_TYPE: u64 = 1;
const E_INSUFFICIENT_PAYMENT: u64 = 2;
const E_ACCESSORY_NOT_FOUND: u64 = 3;
// const E_ACCESSORY_ALREADY_EQUIPPED: u64 = 4; //really should be in use
const E_ACCESSORY_NOT_EQUIPPED: u64 = 5;
const E_MARKETPLACE_PAUSED: u64 = 6;
const E_INVALID_ROYALTY: u64 = 7;

// ==================== Constants ====================
const MAX_ROYALTY_BASIS_POINTS: u64 = 1000; // 10%
const BASIS_POINTS: u64 = 10000;

// ==================== Accessory Types ====================
const ACCESSORY_HEAD_GEAR: u8 = 0;
const ACCESSORY_EYE_GEAR: u8 = 1;
const ACCESSORY_CLOTHING: u8 = 2;
const ACCESSORY_BACK_WEAR: u8 = 3;

// ==================== Core Structs ====================

/// Admin capability for managing the collection
public struct AdminCap has key, store {
    id: UID,
}

/// Collection configuration and metadata
public struct Collection has key {
    id: UID,
    name: String,
    description: String,
    creator: address,
    royalty_basis_points: u64,
    royalty_recipient: address,
    total_supply: u64,
    max_supply: Option<u64>,
    mint_price: u64,
    is_public_mint: bool,
    treasury: Balance<SUI>,
}

/// Character NFT with equipable accessories
public struct Character has key, store {
    id: UID,
    name: String,
    description: String,
    image_url: Url,
    collection_id: ID,
    token_id: u64,
    base_attributes: VecMap<String, String>,
    // Equipped accessories
    head_gear: Option<AccessoryItem>,
    eye_gear: Option<AccessoryItem>,
    clothing: Option<AccessoryItem>,
    back_wear: Option<AccessoryItem>,
    // Metadata tracking
    last_updated: u64,
    update_count: u64,
}

/// Accessory item that can be equipped to characters
public struct AccessoryItem has store, drop {
    id: ID,
    name: String,
    description: String,
    image_url: Url,
    accessory_type: u8,
    rarity: String,
    attributes: VecMap<String, String>,
    created_at: u64,
}

/// Marketplace for trading accessories
public struct Marketplace has key {
    id: UID,
    is_active: bool,
    collection_id: ID,
    listings: Table<ID, Listing>,
    total_volume: u64,
    total_sales: u64,
    fee_basis_points: u64,
    fee_recipient: address,
}

/// Individual accessory listing
public struct Listing has store {
    accessory: AccessoryItem,
    seller: address,
    price: u64,
    listed_at: u64,
}

/// Accessory template for minting new accessories
public struct AccessoryTemplate has key, store {
    id: UID,
    name: String,
    description: String,
    image_url: Url,
    accessory_type: u8,
    rarity: String,
    base_attributes: VecMap<String, String>,
    mint_price: u64,
    max_supply: Option<u64>,
    current_supply: u64,
    is_active: bool,
}

// ==================== Events ====================

public struct CharacterMinted has copy, drop {
    character_id: ID,
    owner: address,
    token_id: u64,
    collection_id: ID,
}

public struct AccessoryEquipped has copy, drop {
    character_id: ID,
    accessory_id: ID,
    accessory_type: u8,
    owner: address,
}

public struct AccessoryUnequipped has copy, drop {
    character_id: ID,
    accessory_id: ID,
    accessory_type: u8,
    owner: address,
}

public struct AccessoryListed has copy, drop {
    accessory_id: ID,
    seller: address,
    price: u64,
    marketplace_id: ID,
}

public struct AccessorySold has copy, drop {
    accessory_id: ID,
    seller: address,
    buyer: address,
    price: u64,
    marketplace_id: ID,
}

// ==================== Init Function ====================
fun init(ctx: &mut TxContext) {
    // Create and transfer admin capability to publisher
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

// ==================== Collection Management ====================

/// Create a new character collection
public entry fun create_collection(
    _: &AdminCap,
    name: String,
    description: String,
    max_supply: Option<u64>,
    mint_price: u64,
    royalty_basis_points: u64,
    royalty_recipient: address,
    ctx: &mut TxContext
) {
    assert!(royalty_basis_points <= MAX_ROYALTY_BASIS_POINTS, E_INVALID_ROYALTY);
    
    let collection = Collection {
        id: object::new(ctx),
        name,
        description,
        creator: tx_context::sender(ctx),
        royalty_basis_points,
        royalty_recipient,
        total_supply: 0,
        max_supply,
        mint_price,
        is_public_mint: false,
        treasury: balance::zero(),
    };
    
    transfer::share_object(collection);
}

/// Enable public minting for the collection
public entry fun enable_public_mint(
    _: &AdminCap,
    collection: &mut Collection,
) {
    collection.is_public_mint = true;
}

/// Disable public minting for the collection
public entry fun disable_public_mint(
    _: &AdminCap,
    collection: &mut Collection,
) {
    collection.is_public_mint = false;
}

// ==================== Character Minting ====================

/// Mint a new base character NFT
public entry fun mint_character(
    collection: &mut Collection,
    name: String,
    description: String,
    image_url: vector<u8>,
    attributes: vector<String>,
    values: vector<String>,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Check if public minting is enabled or if called by creator
    assert!(
        collection.is_public_mint || tx_context::sender(ctx) == collection.creator,
        E_NOT_AUTHORIZED
    );
    
    // Check payment
    assert!(coin::value(&payment) >= collection.mint_price, E_INSUFFICIENT_PAYMENT);
    
    // Check max supply if set
    if (option::is_some(&collection.max_supply)) {
        assert!(
            collection.total_supply < *option::borrow(&collection.max_supply),
            E_INVALID_ACCESSORY_TYPE
        );
    };
    
    // Add payment to treasury
    let payment_balance = coin::into_balance(payment);
    balance::join(&mut collection.treasury, payment_balance);
    
    // Create base attributes map
    let mut base_attributes = vec_map::empty();
    let mut i = 0;
    let len = vector::length(&attributes);
    while (i < len) {
        vec_map::insert(
            &mut base_attributes,
            *vector::borrow(&attributes, i),
            *vector::borrow(&values, i)
        );
        i = i + 1;
    };
    
    // Create character
    let token_id = collection.total_supply + 1;
    let character_id = object::new(ctx);
    let character_id_copy = object::uid_to_inner(&character_id);
    
    let character = Character {
        id: character_id,
        name,
        description,
        image_url: url::new_unsafe_from_bytes(image_url),
        collection_id: object::id(collection),
        token_id,
        base_attributes,
        head_gear: option::none(),
        eye_gear: option::none(),
        clothing: option::none(),
        back_wear: option::none(),
        last_updated: clock::timestamp_ms(clock),
        update_count: 0,
    };
    
    // Update collection supply
    collection.total_supply = collection.total_supply + 1;
    
    // Emit event
    event::emit(CharacterMinted {
        character_id: character_id_copy,
        owner: tx_context::sender(ctx),
        token_id,
        collection_id: object::id(collection),
    });
    
    // Transfer to minter
    transfer::transfer(character, tx_context::sender(ctx));
}

// ==================== Accessory Management ====================

/// Create a new accessory template
public entry fun create_accessory_template(
    _: &AdminCap,
    name: String,
    description: String,
    image_url: vector<u8>,
    accessory_type: u8,
    rarity: String,
    attributes: vector<String>,
    values: vector<String>,
    mint_price: u64,
    max_supply: Option<u64>,
    ctx: &mut TxContext
) {
    assert!(accessory_type <= ACCESSORY_BACK_WEAR, E_INVALID_ACCESSORY_TYPE);
    
    // Create base attributes map
    let mut base_attributes = vec_map::empty();
    let mut i = 0;
    let len = vector::length(&attributes);
    while (i < len) {
        vec_map::insert(
            &mut base_attributes,
            *vector::borrow(&attributes, i),
            *vector::borrow(&values, i)
        );
        i = i + 1;
    };
    
    let template = AccessoryTemplate {
        id: object::new(ctx),
        name,
        description,
        image_url: url::new_unsafe_from_bytes(image_url),
        accessory_type,
        rarity,
        base_attributes,
        mint_price,
        max_supply,
        current_supply: 0,
        is_active: true,
    };
    
    transfer::share_object(template);
}

/// Mint a new accessory from template
public entry fun mint_accessory(
    template: &mut AccessoryTemplate,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
): AccessoryItem {
    assert!(template.is_active, E_NOT_AUTHORIZED);
    assert!(coin::value(&payment) >= template.mint_price, E_INSUFFICIENT_PAYMENT);
    
    // Check max supply if set
    if (option::is_some(&template.max_supply)) {
        assert!(
            template.current_supply < *option::borrow(&template.max_supply),
            E_INVALID_ACCESSORY_TYPE
        );
    };
    
    // Burn payment (or could be sent to treasury)
    transfer::public_transfer(payment, @0x0);
    
    // Create accessory
    let accessory_id = object::new(ctx);
    let accessory_id_copy = object::uid_to_inner(&accessory_id);
    object::delete(accessory_id);
    
    let accessory = AccessoryItem {
        id: accessory_id_copy,
        name: template.name,
        description: template.description,
        image_url: template.image_url,
        accessory_type: template.accessory_type,
        rarity: template.rarity,
        attributes: template.base_attributes,
        created_at: clock::timestamp_ms(clock),
    };
    
    // Update template supply
    template.current_supply = template.current_supply + 1;
    
    accessory
}

// ==================== Character Equipment ====================

/// Equip an accessory to a character
public  fun equip_accessory(
    character: &mut Character,
    accessory: AccessoryItem,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let accessory_type = accessory.accessory_type;
    let accessory_id = accessory.id;
    
    // Check if slot is already occupied and handle accordingly
    if (accessory_type == ACCESSORY_HEAD_GEAR) {
        if (option::is_some(&character.head_gear)) {
            // Unequip existing accessory first
            let old_accessory = option::extract(&mut character.head_gear);
            // Could implement storage or burning logic here
            let AccessoryItem { id: _, name: _, description: _, image_url: _, accessory_type: _, rarity: _, attributes: _, created_at: _ } = old_accessory;
        };
        option::fill(&mut character.head_gear, accessory);
    } else if (accessory_type == ACCESSORY_EYE_GEAR) {
        if (option::is_some(&character.eye_gear)) {
            let old_accessory = option::extract(&mut character.eye_gear);
            let AccessoryItem { id: _, name: _, description: _, image_url: _, accessory_type: _, rarity: _, attributes: _, created_at: _ } = old_accessory;
        };
        option::fill(&mut character.eye_gear, accessory);
    } else if (accessory_type == ACCESSORY_CLOTHING) {
        if (option::is_some(&character.clothing)) {
            let old_accessory = option::extract(&mut character.clothing);
            let AccessoryItem { id: _, name: _, description: _, image_url: _, accessory_type: _, rarity: _, attributes: _, created_at: _ } = old_accessory;
        };
        option::fill(&mut character.clothing, accessory);
    } else if (accessory_type == ACCESSORY_BACK_WEAR) {
        if (option::is_some(&character.back_wear)) {
            let old_accessory = option::extract(&mut character.back_wear);
            let AccessoryItem { id: _, name: _, description: _, image_url: _, accessory_type: _, rarity: _, attributes: _, created_at: _ } = old_accessory;
        };
        option::fill(&mut character.back_wear, accessory);
    } else {
        abort E_INVALID_ACCESSORY_TYPE
    };
    
    // Update character metadata
    character.last_updated = clock::timestamp_ms(clock);
    character.update_count = character.update_count + 1;
    
    // Emit event
    event::emit(AccessoryEquipped {
        character_id: object::id(character),
        accessory_id,
        accessory_type,
        owner: tx_context::sender(ctx),
    });
}

/// Unequip an accessory from a character
public entry fun unequip_accessory(
    character: &mut Character,
    accessory_type: u8,
    clock: &Clock,
    ctx: &mut TxContext
): AccessoryItem {
    assert!(accessory_type <= ACCESSORY_BACK_WEAR, E_INVALID_ACCESSORY_TYPE);
    
    let accessory = if (accessory_type == ACCESSORY_HEAD_GEAR) {
        assert!(option::is_some(&character.head_gear), E_ACCESSORY_NOT_EQUIPPED);
        option::extract(&mut character.head_gear)
    } else if (accessory_type == ACCESSORY_EYE_GEAR) {
        assert!(option::is_some(&character.eye_gear), E_ACCESSORY_NOT_EQUIPPED);
        option::extract(&mut character.eye_gear)
    } else if (accessory_type == ACCESSORY_CLOTHING) {
        assert!(option::is_some(&character.clothing), E_ACCESSORY_NOT_EQUIPPED);
        option::extract(&mut character.clothing)
    } else if (accessory_type == ACCESSORY_BACK_WEAR) {
        assert!(option::is_some(&character.back_wear), E_ACCESSORY_NOT_EQUIPPED);
        option::extract(&mut character.back_wear)
    } else {
        abort E_INVALID_ACCESSORY_TYPE
    };
    
    let accessory_id = accessory.id;
    
    // Update character metadata
    character.last_updated = clock::timestamp_ms(clock);
    character.update_count = character.update_count + 1;
    
    // Emit event
    event::emit(AccessoryUnequipped {
        character_id: object::id(character),
        accessory_id,
        accessory_type,
        owner: tx_context::sender(ctx),
    });
    
    accessory
}

// ==================== Marketplace ====================

/// Create a new marketplace
public entry fun create_marketplace(
    _: &AdminCap,
    collection_id: ID,
    fee_basis_points: u64,
    fee_recipient: address,
    ctx: &mut TxContext
) {
    let marketplace = Marketplace {
        id: object::new(ctx),
        is_active: true,
        collection_id,
        listings: table::new(ctx),
        total_volume: 0,
        total_sales: 0,
        fee_basis_points,
        fee_recipient,
    };
    
    transfer::share_object(marketplace);
}

/// List an accessory for sale
public fun list_accessory(
    marketplace: &mut Marketplace,
    accessory: AccessoryItem,
    price: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(marketplace.is_active, E_MARKETPLACE_PAUSED);
    
    let accessory_id = accessory.id;
    let listing = Listing {
        accessory,
        seller: tx_context::sender(ctx),
        price,
        listed_at: clock::timestamp_ms(clock),
    };
    
    table::add(&mut marketplace.listings, accessory_id, listing);
    
    // Emit event
    event::emit(AccessoryListed {
        accessory_id,
        seller: tx_context::sender(ctx),
        price,
        marketplace_id: object::id(marketplace),
    });
}

/// Purchase a listed accessory
public entry fun purchase_accessory(
    marketplace: &mut Marketplace,
    collection: &mut Collection,
    accessory_id: ID,
    payment: Coin<SUI>,
    ctx: &mut TxContext
): AccessoryItem {
    assert!(marketplace.is_active, E_MARKETPLACE_PAUSED);
    assert!(table::contains(&marketplace.listings, accessory_id), E_ACCESSORY_NOT_FOUND);
    
    let listing = table::remove(&mut marketplace.listings, accessory_id);
    let Listing { accessory, seller, price, listed_at: _ } = listing;
    assert!(coin::value(&payment) >= price, E_INSUFFICIENT_PAYMENT);
    
    let mut payment_balance = coin::into_balance(payment);
    
    // Calculate fees
    let marketplace_fee = (price * marketplace.fee_basis_points) / BASIS_POINTS;
    let royalty_fee = (price * collection.royalty_basis_points) / BASIS_POINTS;
    let _seller_amount = price - marketplace_fee - royalty_fee;
    
    // Distribute payments
    if (marketplace_fee > 0) {
        let fee_balance = balance::split(&mut payment_balance, marketplace_fee);
        transfer::public_transfer(
            coin::from_balance(fee_balance, ctx),
            marketplace.fee_recipient
        );
    };
    
    if (royalty_fee > 0) {
        let royalty_balance = balance::split(&mut payment_balance, royalty_fee);
        transfer::public_transfer(
            coin::from_balance(royalty_balance, ctx),
            collection.royalty_recipient
        );
    };
    
    // Pay seller
    transfer::public_transfer(
        coin::from_balance(payment_balance, ctx),
        seller
    );
    
    // Update marketplace stats
    marketplace.total_volume = marketplace.total_volume + price;
    marketplace.total_sales = marketplace.total_sales + 1;
    
    // Emit event
    event::emit(AccessorySold {
        accessory_id,
        seller,
        buyer: tx_context::sender(ctx),
        price,
        marketplace_id: object::id(marketplace),
    });
    
    accessory
}

/// Cancel a listing
public entry fun cancel_listing(
    marketplace: &mut Marketplace,
    accessory_id: ID,
    ctx: &mut TxContext
): AccessoryItem {
    assert!(table::contains(&marketplace.listings, accessory_id), E_ACCESSORY_NOT_FOUND);
    
    let listing = table::remove(&mut marketplace.listings, accessory_id);
    let Listing { accessory, seller, price: _, listed_at: _ } = listing;
    
    // Only seller can cancel
    assert!(seller == tx_context::sender(ctx), E_NOT_AUTHORIZED);
    
    accessory
}

// ==================== Admin Functions ====================

/// Pause/unpause marketplace
public entry fun set_marketplace_status(
    _: &AdminCap,
    marketplace: &mut Marketplace,
    is_active: bool,
) {
    marketplace.is_active = is_active;
}

/// Withdraw from collection treasury
public entry fun withdraw_treasury(
    _: &AdminCap,
    collection: &mut Collection,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext
) {
    let withdrawal = balance::split(&mut collection.treasury, amount);
    transfer::public_transfer(coin::from_balance(withdrawal, ctx), recipient);
}

/// Update collection royalty
public entry fun update_royalty(
    _: &AdminCap,
    collection: &mut Collection,
    new_royalty_basis_points: u64,
    new_recipient: address,
) {
    assert!(new_royalty_basis_points <= MAX_ROYALTY_BASIS_POINTS, E_INVALID_ROYALTY);
    collection.royalty_basis_points = new_royalty_basis_points;
    collection.royalty_recipient = new_recipient;
}

// ==================== View Functions ====================

/// Get character metadata
public fun get_character_metadata(character: &Character): (
    String, String, Url, u64, u64, u64,
    bool, bool, bool, bool
) {
    (
        character.name,
        character.description,
        character.image_url,
        character.token_id,
        character.last_updated,
        character.update_count,
        option::is_some(&character.head_gear),
        option::is_some(&character.eye_gear),
        option::is_some(&character.clothing),
        option::is_some(&character.back_wear),
    )
}

/// Check if accessory is equipped
public fun is_accessory_equipped(character: &Character, accessory_type: u8): bool {
    if (accessory_type == ACCESSORY_HEAD_GEAR) {
        option::is_some(&character.head_gear)
    } else if (accessory_type == ACCESSORY_EYE_GEAR) {
        option::is_some(&character.eye_gear)
    } else if (accessory_type == ACCESSORY_CLOTHING) {
        option::is_some(&character.clothing)
    } else if (accessory_type == ACCESSORY_BACK_WEAR) {
        option::is_some(&character.back_wear)
    } else {
        false
    }
}
/// Get collection stats
public fun get_collection_stats(collection: &Collection): (u64, u64, u64, bool) {
    (
        collection.total_supply,
        if (option::is_some(&collection.max_supply)) {
            *option::borrow(&collection.max_supply)
        } else { 0 },
        collection.mint_price,
        collection.is_public_mint,
    )
}

/// Get marketplace stats
public fun get_marketplace_stats(marketplace: &Marketplace): (u64, u64, u64, bool) {
    (
        marketplace.total_volume,
        marketplace.total_sales,
        marketplace.fee_basis_points,
        marketplace.is_active,
    )
}

}