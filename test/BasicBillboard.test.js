
const { BigNumber } = web3;
const BasicBillboard = artifacts.require('BasicBillboard');

require('chai')
  .use(require('chai-bignumber')(BigNumber))
  .should();

contract('BasicBillboardMock', ([owner, renter1, renter2]) => {
  let basicBillboard;
  const nullAddress = '0x0000000000000000000000000000000000000000';

  describe("simple cases", () => {
    beforeEach(async () => {
      basicBillboard = await BasicBillboard.new(1);
    });

    it("maintains ownership of token to actual owner", async () => {
      (await basicBillboard.ownerOf(0)).should.equal(owner);
    });

    it("lets renter reserve and gain access", async () => {
      await basicBillboard.reserve(0, 1000, 2000, {from: renter1});

      (await basicBillboard.renterOf(0, 500)).should.equal(nullAddress);
      (await basicBillboard.renterOf(0, 1500)).should.equal(renter1);
    });

    it("blocks off availability after reservation", async () => {
      // available by default
      (await basicBillboard.checkAvailable(0, 0, 5000)).should.equal(true);

      await basicBillboard.reserve(0, 1000, 2000, {from: renter1});
      await basicBillboard.reserve(0, 3000, 4000, {from: renter1});

      // block time range >> reservation 1 and 2
      //  |---------------------|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 0, 5000)).should.equal(false);
      // block time range >> reservation 1 but not 2
      //  |----------|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 500, 2500)).should.equal(false);
      // block time range >> reservation 2 but not 1
      //              |----------|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 2500, 4500)).should.equal(false);
      // block time range starts before reservation 1 and ends during 1
      //  |----|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 500, 1500)).should.equal(false);
      // block time range starts during reservation 1 and ends before 2
      //       |----|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 1500, 2500)).should.equal(false);
      // block time range starts after reservation 1 and ends during 2
      //             |---|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 2500, 3500)).should.equal(false);
      // block time range starts during reservation 2
      //                    |---|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 3500, 4500)).should.equal(false);

      // available time range before reservation 1
      // |--|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 500, 800)).should.equal(true);
      // available time range between reservation 1 and 2
      //            |--|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 2200, 2500)).should.equal(true);
      // available time range after 2
      //                        |--|
      //     |--1--|    |--2--|
      (await basicBillboard.checkAvailable(0, 4500, 5000)).should.equal(true);
    });

    it("prevents double book", async () => {
      await basicBillboard.reserve(0, 1000, 2000, {from: renter1});
      (await basicBillboard.checkAvailable(0, 1000, 2000)).should.equal(false);

      // reserve returns false
      (await basicBillboard.reserve.call(0, 1000, 2000, {from: renter2})).should.equal(false);
      await basicBillboard.reserve(0, 1000, 2000, {from: renter2});

      // reserve from renter2 has no effect
      (await basicBillboard.renterOf(0, 1500)).should.equal(renter1);
    });
  });

  describe("cancellation", () => {
    before(async () => {
      basicBillboard = await BasicBillboard.new(1);

      await basicBillboard.reserve(0, 1000, 2000, {from: renter1});
      await basicBillboard.reserve(0, 3000, 3500, {from: renter1});
      await basicBillboard.reserve(0, 4000, 5000, {from: renter1});
      await basicBillboard.reserve(0, 2500, 2700, {from: renter2});

      await basicBillboard.cancelReservation(0, 1000, 4000, {from: renter1});
    });

    it("makes cancelled time period available gain", async () => {
      (await basicBillboard.checkAvailable(0, 1000, 2000)).should.equal(true);

      (await basicBillboard.renterOf(0, 1500)).should.equal(nullAddress);
      (await basicBillboard.renterOf(0, 3200)).should.equal(nullAddress);
    });

    it("skips reservations that requestor doesn't own", async () => {
      (await basicBillboard.renterOf(0, 2600)).should.equal(renter2);
    });

    it("does not cancel reservations outside requested time range", async () => {
      (await basicBillboard.renterOf(0, 4500)).should.equal(renter1);
    });
  });
});
